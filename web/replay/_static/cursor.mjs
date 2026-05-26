// Browser-side replay cursor module.
//
// Wraps an already-initialised qjs_arena_wasm Module instance and
// exposes the cursor surface from REPLAY_CURSOR_API.md:
//
//   scanIndex(replay)              — cached list of FUNC_ENTER/EXIT/THROW
//                                    events for the whole replay (cheap)
//   materialise(replay, opts)      — one-pass drill: events array,
//                                    stackSnapshots, matchingExit,
//                                    lineIndex, scanOrdinalToEventIdx
//   openCursor(replay, anchor)     — position into the drill stream
//   drillNext(cursor, limit)       — slice the next `limit` events from
//                                    the materialised data
//
// One CursorEngine wraps one long-lived arena and dispatches many
// replays into it; `JS_ResetRequestArena` runs at the top of each
// `arena_run_module` call so per-request state doesn't bleed across
// replays. `drillNext` is a pure slice over `materialise()` output —
// no per-page replay.

const TRACE_OFF = 0, TRACE_SCAN = 1, TRACE_DRILL = 2;
const K_NAME = 0, K_FUNC_ENTER = 1, K_FUNC_EXIT = 2, K_LINE = 3, K_THROW = 4;

const DEFAULT_STACK_SNAPSHOT_STEP = 64;

export class CursorEngine {
    constructor(Module) {
        this.M = Module;
        this._run      = Module.cwrap("arena_run_module",     "number", ["string","string"]);
        this._setMode  = Module.cwrap("arena_set_trace_mode", null,     ["number"]);
        this._snapshot = Module.cwrap("arena_snapshot_here",  "number", []);
        // `docs/primitive-gaps.md` §9: seed the per-context
        // xorshift64star PRNG from the captured request's
        // `replay.seed` so `Math.random` / `crypto.*` reproduce the
        // exact draw sequence. Replay tape no longer carries
        // per-draw entries — this scalar IS the entire input.
        this._setSeed  = Module.cwrap("arena_set_random_seed", null,    ["number","number"]);
        // §9 fold-in: pin `Date.now()` and `new Date()` (no args)
        // to a single ms scalar derived from the request's
        // `timestamp_ns`. Every clock read inside one replay
        // returns the same value — same semantics as the original
        // request's pinned time.
        this._setNow   = Module.cwrap("arena_set_date_now",    null,    ["number","number"]);
        this._scanCache = new WeakMap();
        this._matCache  = new WeakMap();
    }

    _decoder() {
        const M = this.M;
        const dec = new TextDecoder();
        return {
            u32: (p)    => M.HEAPU32[p >> 2],
            u16: (p)    => M.HEAPU16[p >> 1],
            str: (p, n) => dec.decode(M.HEAPU8.subarray(p, p + n)),
        };
    }

    _installReplay(replay) {
        for (const k of Object.keys(replay.tapes)) {
            replay.tapes[k]._cursor = 0;
        }
        this.M.tapes = replay.tapes;
        this.M.module_sources = replay.module_sources ?? {};
        // §8: fresh writeset overlay per replay. `_arena_host_kv_set`
        // / `_kv_delete` write into this Map; `_kv_get` checks it
        // before falling through to the tape. Resetting between
        // replays ensures one replay's writes don't leak into the
        // next.
        this.M._kvOverlay = new Map();
        // §9: seed the per-context PRNG from the captured request's
        // seed. `arena_set_random_seed(seed_lo, seed_hi)` splits the
        // 64-bit seed across two u32 args (WASM ABI). Zero is the
        // default for pre-§9 captures with no seed in the bundle.
        const seed = BigInt(replay.seed ?? 0n);
        const lo = Number(seed & 0xFFFFFFFFn);
        const hi = Number((seed >> 32n) & 0xFFFFFFFFn);
        this._setSeed(lo, hi);
        // §9 fold-in: pin `Date.now()` to ms-since-epoch derived
        // from the captured `timestamp_ns`. Split across two u32
        // args (WASM ABI). `null` (pre-fold-in captures) pins to 0
        // — the same default arenajs uses when no embedder call is
        // made, so handlers that don't read the clock are
        // unaffected.
        const ts_ns = BigInt(replay.timestamp_ns ?? 0n);
        const ms_bi = ts_ns / 1_000_000n;  // ns → ms, truncating
        const ms_lo = Number(ms_bi & 0xFFFFFFFFn);
        const ms_hi = Number((ms_bi >> 32n) & 0xFFFFFFFFn);
        this._setNow(ms_lo, ms_hi);
    }

    async scanIndex(replay) {
        const cached = this._scanCache.get(replay);
        if (cached) return cached;

        this._installReplay(replay);
        const r = this._decoder();
        const atomMap = new Map();
        const fileStack = [];
        const records = [];
        let ordinal = 0, depth = 0;

        this.M.host_trace = (kind, ptr) => {
            if (kind === K_NAME) {
                atomMap.set(r.u32(ptr), r.str(ptr + 6, r.u16(ptr + 4)));
                return 0;
            }
            if (kind === K_FUNC_ENTER) {
                const nameAtom = r.u32(ptr);
                const fileAtom = r.u32(ptr + 4);
                const line = r.u32(ptr + 8);
                const name = atomMap.get(nameAtom) ?? `<atom:${nameAtom}>`;
                const file = atomMap.get(fileAtom) ?? `<atom:${fileAtom}>`;
                depth++;
                fileStack.push(file);
                records.push({
                    ordinal: ordinal++, kind: "FUNC_ENTER",
                    name, file, line, depth,
                });
            } else if (kind === K_FUNC_EXIT) {
                const file = fileStack.pop() ?? "";
                records.push({
                    ordinal: ordinal++, kind: "FUNC_EXIT",
                    file, line: 0, depth,
                });
                depth--;
            } else if (kind === K_THROW) {
                const fileAtom = r.u32(ptr);
                const line = r.u32(ptr + 4);
                const mlen = r.u16(ptr + 8);
                records.push({
                    ordinal: ordinal++, kind: "THROW",
                    file: atomMap.get(fileAtom) ?? `<atom:${fileAtom}>`,
                    line, depth,
                    message: r.str(ptr + 10, mlen),
                });
            }
            return 0;
        };

        this._setMode(TRACE_SCAN);
        this._run(replay.entry.name, replay.entry.src);
        this._setMode(TRACE_OFF);
        this.M.host_trace = null;

        this._scanCache.set(replay, records);
        return records;
    }

    async materialise(replay, opts = {}) {
        const cached = this._matCache.get(replay);
        if (cached) return cached;

        const stackSnapshotStep = opts.stackSnapshotStep ?? DEFAULT_STACK_SNAPSHOT_STEP;

        // Pass 1: drill the replay capturing events + structural sidecars
        // but no variable snapshots. Gives us an exact event count.
        const base = await this._materialisePass1(replay, stackSnapshotStep);

        // Decide variable-snapshot cadence:
        //   - explicit snapshotStep wins if provided
        //   - otherwise targetSnapshots picks the step from pass 1's
        //     event count (UI scrubber width = targetSnapshots)
        //   - else no varSnapshots
        let varStep = 0;
        if (opts.snapshotStep !== undefined && opts.snapshotStep > 0) {
            varStep = opts.snapshotStep;
        } else if (opts.targetSnapshots !== undefined && opts.targetSnapshots > 0
                   && base.events.length > 0) {
            varStep = Math.max(1, Math.ceil(base.events.length / opts.targetSnapshots));
        }

        if (varStep > 0) {
            const varSnapshots = await this._captureVarSnapshots(
                replay, varStep, base.events.length);
            base.varSnapshots = varSnapshots;
            base.varSnapshotStep = varStep;
        }

        this._matCache.set(replay, base);
        return base;
    }

    // Pass 1: drill once, no var snapshots. Builds the events array,
    // stackSnapshots, matchingExit, lineIndex, scanOrdinalToEventIdx.
    async _materialisePass1(replay, stackSnapshotStep) {
        this._installReplay(replay);
        const r = this._decoder();

        const atomMap = new Map();
        const fileStack = [];
        const events = [];
        const matchingExitArr = [];
        const scanOrdinalToEventIdx = [];
        const enterIdxStack = [];
        const liveStack = [];
        const stackSnapshots = [];
        const lineIndex = new Map();

        let scanCounter = 0;
        let depth = 0;

        this.M.host_trace = (kind, ptr) => {
            if (kind === K_NAME) {
                atomMap.set(r.u32(ptr), r.str(ptr + 6, r.u16(ptr + 4)));
                return 0;
            }

            let event;
            let isScan = true;
            if (kind === K_FUNC_ENTER) {
                const nameAtom = r.u32(ptr);
                const fileAtom = r.u32(ptr + 4);
                const line = r.u32(ptr + 8);
                const name = atomMap.get(nameAtom) ?? `<atom:${nameAtom}>`;
                const file = atomMap.get(fileAtom) ?? `<atom:${fileAtom}>`;
                depth++;
                fileStack.push(file);
                event = { kind: "FUNC_ENTER", name, file, line, depth };
            } else if (kind === K_FUNC_EXIT) {
                const file = fileStack.pop() ?? "";
                event = { kind: "FUNC_EXIT", file, line: 0, depth };
                depth--;
            } else if (kind === K_LINE) {
                const fileAtom = r.u32(ptr);
                event = {
                    kind: "LINE",
                    file: atomMap.get(fileAtom) ?? `<atom:${fileAtom}>`,
                    line: r.u32(ptr + 4),
                };
                isScan = false;
            } else if (kind === K_THROW) {
                const fileAtom = r.u32(ptr);
                const line = r.u32(ptr + 4);
                const mlen = r.u16(ptr + 8);
                event = {
                    kind: "THROW",
                    file: atomMap.get(fileAtom) ?? `<atom:${fileAtom}>`,
                    line, depth,
                    message: r.str(ptr + 10, mlen),
                };
            } else {
                return 0;
            }

            if (isScan) {
                event.scanOrdinal = scanCounter;
                scanCounter++;
            } else {
                event.scanOrdinal = Math.max(0, scanCounter - 1);
            }

            const eventIdx = events.length;
            events.push(event);
            matchingExitArr.push(-1);

            // Stack maintenance + matchingExit pairing.
            if (event.kind === "FUNC_ENTER") {
                liveStack.push({
                    name: event.name, file: event.file,
                    line: event.line, depth: event.depth,
                });
                enterIdxStack.push(eventIdx);
            } else if (event.kind === "FUNC_EXIT") {
                liveStack.pop();
                const enterIdx = enterIdxStack.pop();
                if (enterIdx !== undefined) {
                    matchingExitArr[enterIdx] = eventIdx;
                    matchingExitArr[eventIdx] = enterIdx;
                }
            } else if (event.kind === "LINE" && liveStack.length > 0) {
                liveStack[liveStack.length - 1].line = event.line;
            }

            if (isScan) scanOrdinalToEventIdx.push(eventIdx);

            // Sparse stack snapshot every stackSnapshotStep events.
            if (stackSnapshotStep > 0 && (eventIdx % stackSnapshotStep) === 0) {
                stackSnapshots.push(liveStack.map(f => ({ ...f })));
            }

            // lineIndex covers any event with a meaningful (file, line)
            // — UI can filter by kind on read.
            if (event.kind !== "FUNC_EXIT") {
                const key = `${event.file}:${event.line}`;
                let arr = lineIndex.get(key);
                if (!arr) { arr = []; lineIndex.set(key, arr); }
                arr.push(eventIdx);
            }

            return 0;
        };

        this._setMode(TRACE_DRILL);
        this._run(replay.entry.name, replay.entry.src);
        this._setMode(TRACE_OFF);
        this.M.host_trace = null;

        const packedLineIndex = new Map();
        for (const [k, v] of lineIndex) packedLineIndex.set(k, Int32Array.from(v));

        return {
            replay,
            events,
            matchingExit: Int32Array.from(matchingExitArr),
            stackSnapshots,
            stackSnapshotStep,
            lineIndex: packedLineIndex,
            scanOrdinalToEventIdx: Int32Array.from(scanOrdinalToEventIdx),
            varSnapshots: undefined,
            varSnapshotStep: undefined,
            inspectCache: new Map(),
        };
    }

    // Pass 2: drill again, snapshotting variables every `step` events.
    // Stops cleanly via the trace stop sentinel after the last expected
    // event (totalEvents-1) so we never reach the run's post-execution
    // wind-down — that's where dense-snapshot replays were OOMing on
    // accumulated arena leaks (failed allocation during microtask drain
    // for the async-wrapped module body's resolution). All snapshots
    // we wanted are already in hand by then.
    async _captureVarSnapshots(replay, step, totalEvents) {
        this._installReplay(replay);
        const r = this._decoder();
        const varSnapshots = [];
        let pendingSnapshotJson = null;
        let eventIdx = -1;

        this.M.host_state = (ptr, len) => {
            pendingSnapshotJson = r.str(ptr, len);
        };
        this.M.host_trace = (kind) => {
            if (kind === K_NAME) return 0;
            eventIdx++;
            if (eventIdx % step === 0) {
                pendingSnapshotJson = null;
                this._snapshot();
                let frames = [];
                if (pendingSnapshotJson !== null) {
                    try { frames = JSON.parse(pendingSnapshotJson); }
                    catch { frames = []; }
                    pendingSnapshotJson = null;
                }
                varSnapshots.push({ eventOrdinal: eventIdx, frames });
            }
            // Stop after the last expected event — see comment above.
            if (totalEvents > 0 && eventIdx >= totalEvents - 1) return 1;
            return 0;
        };

        this._setMode(TRACE_DRILL);
        this._run(replay.entry.name, replay.entry.src);
        this._setMode(TRACE_OFF);
        this.M.host_trace = null;
        this.M.host_state = null;

        return varSnapshots;
    }

    openCursor(replay, anchor) {
        return { replay, anchor, drillEventsAfterAnchor: 0 };
    }

    async drillNext(cursor, limit) {
        if (!Number.isInteger(limit) || limit <= 0)
            throw new Error("drillNext: limit must be a positive integer");

        const mat = await this.materialise(cursor.replay);
        const anchorIdx = this._anchorToEventIdx(mat, cursor.anchor);
        if (anchorIdx < 0) {
            // Anchor not found in this replay — return empty page,
            // signal end (no more pages to fetch for an unmatched anchor).
            return { events: [], next: null };
        }

        const start = anchorIdx + 1 + cursor.drillEventsAfterAnchor;
        const end = Math.min(start + limit, mat.events.length);
        const events = mat.events.slice(start, end);

        const next = (end < mat.events.length) ? {
            replay: cursor.replay,
            anchor: cursor.anchor,
            drillEventsAfterAnchor:
                cursor.drillEventsAfterAnchor + events.length,
        } : null;

        return { events, next };
    }

    // Exact-precision variable inspection for one event or a window
    // around it. Re-runs the replay with snapshot-at-every-event policy
    // bounded to the requested window. Results cached on the
    // materialised so subsequent fine-steps inside the same window are
    // O(1).
    async inspectAt(mat, eventOrdinal, opts = {}) {
        const cluster = Math.max(0, opts.cluster ?? 0);
        const lo = Math.max(0, eventOrdinal - cluster);
        const hi = Math.min(mat.events.length - 1, eventOrdinal + cluster);
        if (lo > hi) return [];

        // Cache hit: if every ordinal in [lo, hi] is cached, return
        // them in order without re-running.
        const cacheHits = [];
        for (let k = lo; k <= hi; k++) {
            const c = mat.inspectCache.get(k);
            if (!c) { cacheHits.length = 0; break; }
            cacheHits.push(c);
        }
        if (cacheHits.length === hi - lo + 1) return cacheHits;

        this._installReplay(mat.replay);
        const r = this._decoder();
        let pendingSnapshotJson = null;
        this.M.host_state = (ptr, len) => {
            pendingSnapshotJson = r.str(ptr, len);
        };

        const results = [];
        let eventIdx = -1;

        this.M.host_trace = (kind) => {
            if (kind === K_NAME) return 0;
            eventIdx++;
            if (eventIdx >= lo && eventIdx <= hi) {
                pendingSnapshotJson = null;
                this._snapshot();
                let frames = [];
                if (pendingSnapshotJson !== null) {
                    try { frames = JSON.parse(pendingSnapshotJson); }
                    catch { frames = []; }
                    pendingSnapshotJson = null;
                }
                results.push({ eventOrdinal: eventIdx, frames });
            }
            if (eventIdx >= hi) return 1;
            return 0;
        };

        this._setMode(TRACE_DRILL);
        this._run(mat.replay.entry.name, mat.replay.entry.src);
        this._setMode(TRACE_OFF);
        this.M.host_trace = null;
        this.M.host_state = null;

        for (const snap of results) {
            mat.inspectCache.set(snap.eventOrdinal, snap);
        }
        return results;
    }

    _anchorToEventIdx(mat, anchor) {
        if (anchor.kind === "scan") {
            const ord = anchor.ordinal;
            if (ord < 0 || ord >= mat.scanOrdinalToEventIdx.length) return -1;
            return mat.scanOrdinalToEventIdx[ord];
        }
        // line anchor
        const after = anchor.afterScan ?? 0;
        const afterEventIdx = (after < mat.scanOrdinalToEventIdx.length)
            ? mat.scanOrdinalToEventIdx[after]
            : -1;
        const key = `${anchor.file}:${anchor.line}`;
        const indices = mat.lineIndex.get(key);
        if (!indices) return -1;
        for (let i = 0; i < indices.length; i++) {
            const idx = indices[i];
            if (idx > afterEventIdx && mat.events[idx].kind === "LINE") {
                return idx;
            }
        }
        return -1;
    }
}
