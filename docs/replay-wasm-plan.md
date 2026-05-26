# Replay-WASM plan — browser-side scrubbing via arenajs compiled to WebAssembly

> **2026-05-15 status update.** The iframe-debugger shell described
> below (`web/replay/_static/app.js` + iframe `index.html`) has been
> retired. The WASM-driven shell is now the single replay surface,
> served from `replay.{public_suffix}/` (formerly `/wasm`). The
> dashboard's two Replay buttons have collapsed into one. Sections
> below that still talk about "the iframe path" or `/wasm` as a
> distinct URL describe the pre-cutover state and are kept for
> historical context — read with that in mind.

The replay UI under `web/replay/_static/` boots the captured
handler through **arenajs compiled to WebAssembly** — the same
engine that ran the handler in production. The browser gets a
programmable execution surface (trace events, stop sentinels,
stack-state snapshots) and the UI is whatever we render on top:
appbar, modules rail, source viewport with line highlighting,
event stream, scrubber with event-indexed ticks, stack breadcrumb
derived from FUNC_ENTER/EXIT events. Everything beyond that —
interactive scrubbing, full variable inspection, stepping via the
cursor API — is the next set of milestones.

---

## 1. Status

### Done

- arenajs WASM build (`qjs_arena_wasm.{js,wasm}`) — ~1 MiB total,
  embedded as a `__replay__` static asset.
- Replay-mode bindings for all five captured tape channels (kv,
  date, math_random, crypto_random, module loader). The five JS
  globals (`kv.*`, `Math.random`, `Date.now`, `new Date()`,
  `crypto.*`) read from tapes the host supplies via
  `Module.tapes`.
- Module loader for replay — pulls source from
  `Module.module_sources` keyed by the resolved specifier the tape
  records, with the default QJS normalizer handling `./` / `../`.
- Trace emitter with `off` / `scan` / `drill` modes. Events:
  `FUNC_ENTER`, `FUNC_EXIT`, `LINE`, `THROW`, plus `NAME` for
  out-of-band string interning. Binary wire format, ~10 µs per
  event over the JS-WASM boundary.
- Stack walker. When the host's `host_trace` callback returns `2`,
  the WASM runtime walks live frames and ships a JSON snapshot via
  `host_state` before raising the stop sentinel. Surfaces args,
  locals, captured-locals, and closure-referenced names.
- RTAP wire-format parser (`web/replay/_static/rtap.mjs`) — mirrors
  `src/tape/root.zig` rule-for-rule with `parseTapeBlob`,
  `serializeTape`, and a `buildTapesFromBlobs` bridge that produces
  the `Module.tapes` shape the WASM bindings consume.
- Entry-point HTML + driver (`web/replay/_static/index.html` +
  `wasm-app.mjs` + `cursor.mjs` (`CursorEngine`)) wired to the
  dashboard's existing postMessage handshake. Boots the engine,
  sets tapes + module sources, and drives interactive scrubbing,
  stepping, and variable inspection via `CursorEngine`
  (`materialise()`, `inspectAt()`, `drillNext()`).

### What's not done (roughly in order of usefulness)

- Source-map remapping — handlers may be transpiled; LINE events
  report bundled lines and the UI needs to map back to user source.
  (§8.6)
- Conditional breakpoints + scope eval — needs `JS_EVAL_TYPE_DIRECT`
  exposed across the WASM boundary. Significant arenajs work.
  (§8.7)
- Snapshot-based fast stepping — capture WASM heap at each stop
  point to avoid full re-runs per step. (§8.8)

### Smoke coverage landed — see `scripts/replay_wasm_smoke.py` and
### `scripts/replay_shell_smoke.mjs` (Playwright). Dev bringup is
### `scripts/replay_wasm_dev.py` (there is no `loop46 dev`
### subcommand).

---

## 2. Architecture overview

```
┌─────────────────────────────────────┐
│ dashboard at app.{suffix}          │
│ - composes ReplayBundle from log    │
│   record + tape blobs               │
│ - window.opens replay.{suffix}/      │
│ - postMessage replay:bundle once    │
│   the replay shell signals ready    │
└──────────────────┬──────────────────┘
                   │ postMessage
                   ▼
┌─────────────────────────────────────────────────────────┐
│ replay.{suffix}/ — index.html + wasm-app.mjs + cursor.mjs │
│                                                         │
│ 1. handshake: replay:ready ──▶  ◀── replay:bundle      │
│                                                         │
│ 2. parse tape_blobs                                    │
│    rtap.mjs:parseTapeBlob → buildTapesFromBlobs        │
│    → Module.tapes = { kv: [], date: [], ... }          │
│                                                         │
│ 3. flatten module sources by path                      │
│    → Module.module_sources = { "lib/x.mjs": "..." }    │
│                                                         │
│ 4. install Module.host_trace = (kind, ptr, len) ⇒ …    │
│                                                         │
│ 5. boot qjs_arena_wasm.js → getArenaJs() → Module       │
│    arena_init(base_kb, request_kb)                      │
│    arena_set_trace_mode(SCAN | DRILL)                   │
│    arena_run_module(entry_path, entry_source)          │
│                                                         │
│ 6. host_trace fires per event during the run.          │
│    Driver decodes the binary payload from HEAP*        │
│    views, builds the timeline, optionally returns 1    │
│    (stop) or 2 (stop + inspect via host_state) to      │
│    halt at a chosen point.                              │
│                                                         │
│ 7. arena_destroy                                       │
└─────────────────────────────────────────────────────────┘
```

The whole flow is local to the replay tab. There's no worker
round-trip; the dashboard supplies all the bytes the WASM module
needs (tapes + source). That keeps the runtime fully sandboxed —
the replay tab can't reach customer data the dashboard didn't
already have authority to load.

---

## 3. WASM module API

The Emscripten build exposes a small C surface. `wasm-app.mjs`
wraps each export with `Module.cwrap` to call from JS.

### Exports

| C signature                                            | JS cwrap call                                                      | What it does                                                                                                                       |
|-------------------------------------------------------|--------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|
| `int arena_init(int base_kb, int request_kb)`          | `cwrap("arena_init", "number", ["number","number"])`               | Allocate the dual arena and freeze base. Call once per page load. Returns 0 on success, -1 on OOM / re-init.                       |
| `int arena_run(const char *src)`                       | `cwrap("arena_run", "number", ["string"])`                          | Evaluate JS source as global script (no module imports). Returns 0 ok, -1 on exception. Used for diagnostics, not for replay.       |
| `int arena_run_module(const char *path, const char *src)` | `cwrap("arena_run_module", "number", ["string","string"])`         | Evaluate `src` as the body of a module named `path`. Inner `import` statements trigger the replay loader. Returns 0 or -1.        |
| `void arena_set_trace_mode(int mode)`                  | `cwrap("arena_set_trace_mode", null, ["number"])`                   | `0` = off (zero overhead), `1` = scan (FUNC_ENTER / EXIT / THROW), `2` = drill (also LINE events).                                  |
| `void arena_destroy(void)`                             | `cwrap("arena_destroy", null, [])`                                  | Tear down. Call before navigating away to keep the linear-memory peak bounded across replays.                                       |
| `void *_malloc(int size) / void _free(void *)`         | usually invoked from EM_JS bodies, not directly                     | Emscripten libc primitives, exported so host imports can allocate WASM-side scratch buffers (e.g. for kv `get` return values).      |

### Module-side state (set BEFORE calling `arena_run_module`)

| Property                  | Type                                                | Used by                                                                                                                                                              |
|---------------------------|-----------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Module.tapes`            | `{ kv: [...], date: [...], math_random: [...], crypto_random: [...], module: [...] }` | Replay bindings. Per-entry shape mirrors `parseTapeBlob` output; see §4.                                                                                             |
| `Module.module_sources`   | `{ [path: string]: string }`                        | Module loader. Lookup is by path first, then by `source_hash_hex` if the path isn't there (lets either keying scheme work).                                          |
| `Module.host_trace`       | `(kind: number, payload_ptr: number, payload_len: number) => 0\|1\|2` | Trace emitter. Sync callback fired during execution. Return non-zero to halt; see §6.                                                                                |
| `Module.host_state`       | `(payload_ptr: number, payload_len: number) => void` | Stack-state delivery. Fires when `host_trace` returned 2; payload is a JSON string. See §7.                                                                          |

The HEAP views needed to decode binary payloads (`Module.HEAPU8`,
`HEAPU16`, `HEAPU32`) are also exported on the Module object — they
were added to `-sEXPORTED_RUNTIME_METHODS` specifically so the host
can read trace payloads. Don't cache them across `arena_init`
calls; Emscripten can reallocate the heap and the views need to be
re-read from Module.

### Things the WASM module does NOT do

- It does not fetch anything. All bytes (sources, tapes) come from
  JS via `Module.*`.
- It does not maintain cursor state for tapes across runs — each
  `Module.tapes` assignment is treated as fresh. To "replay
  twice," reassign `Module.tapes` to a fresh object (or rebuild
  via `buildTapesFromBlobs`).
- It does not GC tape entries after consumption. The host can
  consult `Module.tapes` mid-run; the EM_JS bindings track each
  channel's cursor in `Module.tapes.<channel>._cursor`.

---

## 4. Tape format and the rtap.mjs bridge

The wire format is defined in `src/tape/root.zig` and parsed in
`web/replay/rtap.mjs`. The latter is a near-line-for-line port of
the recorder's encoding rules:

```
Per-tape:
  [u32 magic = 0x52544150 'RTAP']
  [u16 version = 1]
  [u16 channel (0=kv, 1=date, 2=math_random, 3=crypto_random,
                4=module, 5=fetch_responses, 6=trigger_payload)]
  [u32 entry_count]
  for each entry: [u32 len][entry bytes]

All multi-byte ints are big-endian.
```

Per-channel entry layouts:

```
kv       (channel 0):
  [u8 op (0=get,1=set,2=delete,3=prefix)]
  [u8 outcome (0=ok,1=not_found,2=err)]
  [u32 len][key utf-8]
  if op != prefix: [u32 len][value utf-8]
  if op == prefix:
    [u32 len][cursor utf-8]
    [u32 limit]
    [u32 result_count]
    repeat: [u32 len][key][u32 len][value]

date     (channel 1):
  [i64 ms_epoch]

math_random   (channel 2):
  [f64 value]

crypto_random (channel 3):
  [u32 len][raw bytes]

module   (channel 4):
  [u32 len][specifier utf-8]
  [u32 len][source_hash_hex utf-8]   // always 64 chars

fetch_responses (channel 5):   // readset-replication-plan §2c-2
  [u32 len][fetch_id utf-8]
  [u32 seq]
  [u64 byte_offset]
  [u64 body_ref.batch_id]
  [u64 body_ref.offset]
  [u32 body_ref.len]
  [u8  final]
  [u16 terminal_status]              // 0 if !final
  [u8  terminal_ok]                  // 0 if !final
  [u8  body_truncated]               // 0 if !final
  [u32 len][headers utf-8]           // non-empty on seq=0 only

trigger_payload (channel 6):   // readset-replication-plan §2d/§4-inline
  [u64 body_ref.batch_id]            // NO_BATCH(0) ⇒ inline bytes
  [u64 body_ref.offset]
  [u32 body_ref.len]                 // when inline, == inline_bytes.len
  [u32 len][headers utf-8]           // reserved; empty for now
  [u32 len][inline_bytes]            // present when batch_id == NO_BATCH
                                     // (small-body inline path); empty
                                     // for the BodyRef-to-S3 path
```

### Bridge to `Module.tapes`

`rtap.mjs` exposes:

```js
parseTapeBlob(bytes: Uint8Array)
    → { channel: number, entries: Object[] }

serializeTape(channel: number, entries: Object[])
    → Uint8Array
    // useful for tests; mirrors the Zig encoder exactly

buildTapesFromBlobs(blobs: { kv?: Uint8Array, date?: Uint8Array, ... })
    → { kv: [...], date: [...], math_random: [...], crypto_random: [...], module: [...] }
    // the shape the WASM bindings consume
```

`buildTapesFromBlobs` is the only function `wasm-app.mjs` calls.
Bundles arrive with `bundle.tape_blobs.<channel>` as `Uint8Array`s
(`null` for channels with no entries — `buildTapesFromBlobs` treats
those as empty arrays).

The lift target for this module is rove proper. It currently lives
at `web/replay/_static/rtap.mjs` alongside the consumers; if it
ever needs to be shared more broadly it could move to a shared
static path. Not urgent for v1.

---

## 5. Trace emitter

### Modes

Set via `arena_set_trace_mode(N)` at any point — read at each
`arena_run_module` start.

| Mode | Constant | Events emitted                                                                            | Overhead                                                                                |
|------|---------:|-------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| OFF  | 0        | none                                                                                      | zero — the dispatch-loop hook compiles to `if (0) ...` and gets folded away             |
| SCAN | 1        | `FUNC_ENTER`, `FUNC_EXIT`, `THROW` (+ `NAME` for new atoms)                                | ~one host_trace call per function call + per throw — negligible at 10 ms handler scale  |
| DRILL| 2        | scan events plus `LINE` on every source-line transition                                   | order of magnitude higher — one call per line crossing per opcode (a few k events typical) |

### Wire format (binary, little-endian within payloads)

The host reads payloads through `Module.HEAPU8` / `HEAPU16` /
`HEAPU32` starting at `payload_ptr`.

```
NAME       kind = 0   bookkeeping; emitted once per JSAtom referenced
  [u32 atom][u16 name_len][name_len utf-8 bytes]

FUNC_ENTER kind = 1
  [u32 name_atom][u32 file_atom][u32 line]

FUNC_EXIT  kind = 2
  (empty payload)

LINE       kind = 3   only in drill mode; per source-line crossing
  [u32 file_atom][u32 line]

THROW      kind = 4   before the throw is processed
  [u32 file_atom][u32 line][u16 msg_len][msg_len utf-8 bytes]
```

`name_atom` and `file_atom` are `JSAtom`s — stable u32 ids per
runtime. The host maintains a `Map<atom, string>` populated from
`NAME` events; later events reference by atom only.

### host_trace return codes

The EM_JS thunk in `qjs-arena-trace.c` coerces any non-`1`-or-`2`
return into `0`, so falsy / unset / wrong-type returns are safe.

| Return | Effect                                                                                                                    |
|--------|---------------------------------------------------------------------------------------------------------------------------|
| 0      | Continue execution.                                                                                                       |
| 1      | Stop cleanly. WASM raises an `InternalError` whose message is exactly `_arena_trace_stop_`; `arena_run_module` recognises that sentinel and returns 0 (not -1). The host knows the run was halted on purpose. |
| 2      | Stop AND inspect: WASM walks live stack frames first, ships a JSON snapshot via `host_state(ptr, len)`, then does the same stop-sentinel unwind. |

Once a stop is signalled, all subsequent events from the unwind
path are suppressed by an internal bail flag — the host sees
exactly the events leading up to the stop, no flurry of trailing
`FUNC_EXIT`s as the stack unwinds.

### Common host_trace patterns

```js
// Collect everything, never stop — the v1 timeline pass.
Module.host_trace = (kind, ptr, len) => { collect(kind, ptr, len); return 0; };

// Source breakpoint at file:line — drill mode.
Module.host_trace = (kind, ptr, len) => {
    if (kind === K_LINE) {
        const f = HEAPU32[ptr >> 2], l = HEAPU32[(ptr + 4) >> 2];
        if (breakpoints.has(`${nameOf(f)}:${l}`)) return 2;
    }
    return 0;
};

// Scrub to event N — host_trace counts events itself.
let i = 0;
Module.host_trace = (kind, ptr, len) => {
    // Skip NAME events from the counter; they're out-of-band.
    if (kind !== K_NAME) i++;
    return i === target ? 2 : 0;
};
```

---

## 6. Stack walker

Active when `host_trace` returns `2`. WASM walks the live frame
chain BEFORE unwinding, builds a JSON document of frames + their
state, and delivers it through `Module.host_state(ptr, len)`. The
host's `host_state` body typically does:

```js
Module.host_state = (ptr, len) => {
    const json = new TextDecoder().decode(Module.HEAPU8.subarray(ptr, ptr + len));
    snapshot = JSON.parse(json);
};
```

The JSON document is an array of frames, top-of-stack first:

```jsonc
[
  {
    "func": "inner",          // function name; "<eval>" for module bodies
    "file": "handler.mjs",    // module path / filename
    "line": 12,                // current source line (resolved via pc2line)
    "vars": {
      "x": 7,                  // args, function locals, captured-locals,
      "prefix": "rove:",       // and closure-referenced names from outer
      "obj": { "k": 1 },       // scopes — all merged into one object
      "fn":  "[function f]",   // value placeholders for unrepresentable
      "u":   "[undefined]",    // values (see below)
    }
  },
  { "func": "outer", "file": "...", "line": ..., "vars": { ... } },
  { "func": "<eval>", "file": "...", "line": 0, "vars": { /* module top-level lets */ } }
]
```

### What's enumerated

For each frame the walker emits both:

1. **Args + locals** in `b->vardefs[0..arg_count+var_count)`. The
   value comes from `sf->arg_buf` / `sf->var_buf`, OR — when the
   vardef has `is_captured` set — from `sf->var_refs[var_ref_idx]`
   (the captured-local path). This makes module-top-level
   `let`/`const` visible on the `<eval>` frame, because they're
   declared as captured locals on the module body.
2. **Closure-referenced names** in `b->closure_var[0..closure_var_count)`.
   The value comes from the function-object's
   `p->u.func.var_refs[i]` (NOT `sf->var_refs`, which holds the
   frame's own captured locals). This is how inner functions see
   variables from outer scopes — including how `bump(n)` inside a
   module sees `appName` and `counter` declared at the module top.

Locals take precedence when a name appears in both lists (rare in
well-formed code; happens with `with` or parameter shadowing).

### Value placeholders

`JSON.stringify` drops some values silently. The walker
pre-processes each value to surface what's there:

| Type          | Output                                  | Notes                                                                                                       |
|---------------|-----------------------------------------|-------------------------------------------------------------------------------------------------------------|
| number/string/bool/null/array/plain object | as-is (real JSON)                       | Nested objects are recursively serialised by `JSON.stringify`.                                              |
| undefined     | `"[undefined]"`                         | Distinguishable from a property that just isn't there.                                                      |
| function      | `"[function <name>]"`                   | Name lifted from `fn.name`. Anonymous functions become `"[function ]"`.                                     |
| symbol        | `"[Symbol]"`                            |                                                                                                             |
| BigInt        | `"[unserializable]"`                    | Probe-stringify rejects; we ship a placeholder.                                                             |
| cycle         | `"[unserializable]"` (whole frame's vars may drop) | One bad var doesn't kill the whole snapshot — each is probe-stringified independently. Cycles fall to placeholder. |
| TDZ slot      | `"[uninitialized]"`                     | `let x; ... use x ...` between hoisted decl and assignment.                                                 |

### Stop semantics + the inspection point

The exact "moment" of the snapshot is BEFORE the opcode at
`frame.cur_pc` executes. So `let c = ...` at line 4: stopping at
the LINE event for line 4 sees `c === "[uninitialized]"`, and
stopping at the next event (e.g. line 5) sees `c` with its
assigned value. This matches how every other debugger works but is
worth knowing when building the UI.

---

## 7. Quirks the UI needs to handle

### Module bodies emit a suspend/resume cycle

QJS-ng wraps every module body in an async function (so top-level
`await` works). Even a fully-synchronous module body shows up in
the trace as **two** FUNC_ENTER / FUNC_EXIT pairs for `<eval>`:
one for the initial physical call (which suspends after creating
the resolution promise) and one for the resume (which runs the
actual user code). Don't be surprised by `<eval>` appearing twice
in a row in the timeline — the UI may want to fold those into one
logical "module body" entry.

### pc2line is sparse

QJS doesn't emit a pc2line entry for every source line. Lines
that compile to identical opcode shape can share an entry, so the
LINE event stream skips some lines. Common pattern: `return X`
often doesn't get its own entry — the return shares a pc2line
record with the previous statement. Stepping UIs shouldn't assume
"next LINE event = next source line."

### Async/generator resume re-enters the dispatch loop

Each suspend/resume cycle of an async function is its own physical
JS_CallInternal call. The trace emitter fires FUNC_ENTER on both
the initial call and each resume (matched with FUNC_EXIT on each
suspend). For a sync module body this is the module
suspend/resume artifact above. For real async handlers it's many
events.

### LINE events fire BEFORE the opcode

So stopping at a LINE event sees state at the START of that line,
not the end. See "Stop semantics" in §6.

### Module-level `let` lives in closure storage

Already covered in §6 but worth flagging here: a UI that wants to
show "module-level state" needs to look at the `<eval>` frame's
vars or any inner function's closure-var section, not at some
"global" namespace. Module top-level lets are NOT on `globalThis`.

### Native arenajs has zero overhead

`ARENA_TRACE_ENABLED` defaults to 0; the rove worker links zero
trace symbols (`nm libqjs.a | grep arena_trace` returns nothing).
The WASM build sets it to 1 via the CMake target. So none of this
machinery costs the production worker anything — relevant if
anyone wonders whether the trace work needs feature-flagging or
build-time toggling. It doesn't.

---

## 8. Roadmap — what to build next, in order

### 8.1 Real-world bundle test — DONE (commit c23257d)

Dev cluster bringup via `scripts/replay_wasm_dev.py` (there is no
`loop46 dev` subcommand). Smoke coverage in
`scripts/replay_wasm_smoke.py` and `scripts/replay_shell_smoke.mjs`
(Playwright).

### 8.2 Source view — DONE

Source-view column alongside the timeline; shows handler source
with line numbers and current-line cursor. Click a timeline row
to jump to `(file, line)` in the source view.

### 8.3 Drill toggle + click-to-inspect — DONE

SCAN/DRILL mode toggle. Timeline rows are interactive: clicking
a row stops at that event index, delivers a stack snapshot via
`host_state`, renders the variable panel. `CursorEngine`
(`cursor.mjs`) abstracts this re-run/stop/inspect loop.

### 8.4 Breakpoints — DONE

Gutter-clickable source lines set breakpoints (`Set<"path:line">`).
`host_trace`'s LINE case checks the set and returns 2 on match.

### 8.5 Stepping — DONE

Step over / into / out implemented as host-side event-counting
state machines in `CursorEngine` (`drillNext()`). Each step is
one full `arena_run_module` call from scratch.

### 8.6 Source-map remapping (small but situational)

If the original handler was transpiled, LINE events report
bundled lines. Apply a source-map at render time in the source
view + on timeline labels. The bundle would need to carry source
maps; PLAN §10.12 doesn't mandate that yet, but `bundle.modules`
could grow a `.sourceMap` field per module.

### 8.7 Conditional breakpoints + scope eval (v2)

Needs `JS_EVAL_TYPE_DIRECT` exposed across the WASM boundary so
the host can evaluate an arbitrary expression in the paused
frame's scope. Significant new arenajs work — defer until a real
use case demands it.

### 8.8 Snapshot-based fast stepping (v2 perf)

If the ~150 ms per step becomes a UX problem, capture the WASM
heap (`Module.HEAPU8` plus the cursor field of each arena) at
each stop point and restore it for the next step. Save/restore
into a JS-side `Uint8Array` is essentially `.set()` calls — fast.
The wrinkle is that QJS's C stack lives in the WASM module's call
stack, not in linear memory, so a heap snapshot alone doesn't
capture "where the interpreter is." See conversation notes for
the two ways around that.

---

## 9. Build + asset update

### Updating the WASM payload

The WASM artefact is built from the vendored arenajs source at
`vendor/arenajs` (v0.1.0). Build via the vendor bump process
documented in `vendor/README.md`; outputs are copied into
`web/replay/_static/` (not `web/replay/`):

```bash
# 1. emsdk available somewhere; the repo currently uses ~/src/emsdk
source ~/src/emsdk/emsdk_env.sh

# 2. configure + build arenajs WASM target from the vendored source
cd vendor/arenajs
mkdir -p build-wasm && cd build-wasm
emcmake cmake .. -DCMAKE_BUILD_TYPE=Release
emmake make qjs_arena_wasm

# 3. copy the two outputs into the static assets directory
cp build-wasm/qjs_arena_wasm.js   ../../web/replay/_static/
cp build-wasm/qjs_arena_wasm.wasm ../../web/replay/_static/

# 4. rebuild rove
cd ../../
zig build test
```

The arenajs side has 102 smoke tests across 7 files under
`tests/wasm/` exercising every binding, the trace emitter, the
stack walker, the closure-var path, and the RTAP wire format.
Run those before copying artifacts in if you've touched arenajs:
`for f in tests/wasm/*-smoke.mjs; do node "$f" || echo FAIL "$f"; done`
from the arenajs build-wasm dir.

### Updating rtap.mjs

The parser is also kept in arenajs/tests/wasm/rtap.mjs for
arenajs's own tests. If you change the wire format on the rove
side (`src/tape/root.zig`), update both copies. The arenajs
contract test (`tests/wasm/wire-smoke.mjs`) catches mismatches by
synthesizing the same bytes the Zig recorder would, then parsing
+ feeding the result through the WASM bindings.

A future improvement is to make rove the source of truth for
rtap.mjs and have arenajs's tests pull from there — but the
arenajs repo wants to be self-contained for its own tests, so
keeping two synchronised copies is the lower-friction option for
now.

### Native worker is untouched

The rove worker links against `vendor/arenajs` (a source snapshot
at the pinned commit in `vendor/arenajs/README.md`). That build
defaults `ARENA_TRACE_ENABLED=0` and pays zero overhead for the
trace machinery. Updating the WASM artefacts does not require
updating `vendor/arenajs`; the two builds are independent.

If you DO want to update `vendor/arenajs` to a newer commit,
follow the existing vendor process documented in
`vendor/README.md` and re-run `zig build test` to verify nothing
regressed.

---

## 10. References

- `vendor/arenajs/qjs-arena-trace.{h,c}` — trace emitter
  implementation.
- `vendor/arenajs/qjs-arena-replay-bindings.{h,c}` — replay-mode
  JS bindings (kv, date, math, crypto + Date constructor wrapper).
- `vendor/arenajs/qjs-arena-reactor.c` — `arena_init` /
  `arena_run_module` / etc.
- `vendor/arenajs/tests/wasm/` — smoke tests for every layer of
  the WASM build. Useful as worked examples of how the host side
  is supposed to wire up.
- `src/tape/root.zig` — authoritative wire format definition.
- `web/replay/_static/wasm-app.mjs` — WASM driver; boots the
  engine, sets tapes + module sources, wires the postMessage
  handshake.
- `web/replay/_static/cursor.mjs` — `CursorEngine`
  (`materialise()`, `inspectAt()`, `drillNext()`), the core
  driver abstraction the shell uses for scrubbing, stepping, and
  variable inspection.
