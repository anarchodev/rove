# Refactoring audit — correctness & clarity pass, 2026-07

Status: **Wave 1 landed, 2026-07-08** (branch `worktree-refactor-audit-doc`,
8 commits — one per item, see §10; §1.3 shipped as lockstep-enforcement
rather than re-export, noted inline). Waves 2–4 not started. This doc records a
whole-codebase audit for refactoring opportunities: god structs, oversized
files, duplicated machinery where one thing should be expressed in terms of
another, and any remaining Zig that should be JS. Six subsystem sweeps fed it
(JS worker cluster, h2/io, consensus/kv, the four binaries, Zig→JS candidates,
storage leaves). Line numbers are as of `main` at `da7b26f`.

The headline: the codebase is in better shape than its file sizes suggest.
The Zig→JS lift is essentially complete (§8), the layering people might worry
about is actually clean (§9), and the biggest "god file" (`dispatcher.zig`,
7k lines) is 86% inline tests. The real debt is **copy-paste drift**: the same
machinery hand-rolled 3–11 times across activation paths, binaries, and
codecs — with four cases where copies have already diverged in ways that
matter (§1).

Suggested reading order: §1 (fix regardless), §2 (the one big unification),
then per-subsystem sections as you touch those areas. §10 sequences the work.

---

## 1. Latent correctness issues (fix these regardless of any refactor)

Four small, independent items. Each closes a real drift hazard; none is a
live production bug today, which is exactly why they'll bite later.

### 1.1 `awaitCommit` in the tenant-move path omits the fault check

There are two blocking "propose, spin until commit watermark" loops. The
directory's is correct — `src/cp/directory.zig:488` (`applyDirWrite`):

```zig
const seq = bridge.proposePut(self.dir_gid, key, value) catch return Error.Replication;
const deadline = std.time.nanoTimestamp() + COMMIT_TIMEOUT_NS;
while (bridge.committedSeq(self.dir_gid) < seq) {
    if (bridge.faultedSeq(self.dir_gid) >= seq) return Error.Replication;  // fail-fast
    if (std.time.nanoTimestamp() > deadline) return Error.Replication;
    std.Thread.sleep(200 * std.time.ns_per_us);
}
```

The tenant-move copy is missing the `faultedSeq` branch —
`src/js/v2_move.zig:912` (`awaitCommit`):

```zig
const deadline = std.time.nanoTimestamp() + worker.commit_wait_timeout_ns;
while (std.time.nanoTimestamp() < deadline) {
    if (worker.raft.committedSeq(gid) >= target_seq) return true;
    std.Thread.sleep(200 * std.time.ns_per_us);          // no faultedSeq() branch
}
return worker.raft.committedSeq(gid) >= target_seq;
```

If this node loses the anchor group's leadership mid-propose during a live
move, the bridge faults the seq but `awaitCommit` ignores it and spins the
full `commit_wait_timeout_ns` — turning a fast, retryable failover into a
multi-second stall on the move critical path. The async worker paths
(`worker_ws.zig:286`, `worker_drain.zig:135`) check both watermarks, proving
the intended contract. A third un-fault-checked copy lives in the directory
test at `directory.zig:1614`.

**Fix:** one `bridge.awaitCommit(gid, seq, timeout_ns) Error!void` (checks
`committedSeq`, `faultedSeq`, deadline) next to `proposePut`; route
`applyDirWrite`, `v2_move.awaitCommit`, and the test through it. Collapses
three blocking impls to one and fixes the fault gap for free. (The async
parked-entity model — `drainRaftPending` — is a genuinely different
non-blocking design and stays separate.)

### 1.2 Envelope codec exists in three copies with divergent `MAX_ID_LEN`

The wire codec is triplicated:

- `src/kv/envelope_codec.zig` — header codec, `MAX_ID_LEN = 256` (line 25).
  Its own doc-comment admits (lines 17–21): "Byte-identical to
  `src/consensus/envelope.zig` … the two stay in sync until the V1 cutover."
  The cutover happened; the sync duty didn't get retired.
- `src/consensus/envelope.zig` — superset (adds `EntryFrame`,
  `WriteSetPayload`, the `Type` enum), `MAX_ID_LEN = 512` (line 27).
- `src/js/apply.zig` — its own `EnvelopeType` enum (80–114) and a
  byte-identical copy of the `WriteSetPayload` encode/decode
  (`apply.zig:144-170` vs `envelope.zig:189-212`). The multi wrapper is
  hand-rolled a third time in `envelope_codec.zig:80-123`.

The id-length caps disagree: a producer encoding through `apply.zig`
(→ `kv.encodeEnvelope`) rejects ids above **256** bytes, but the consensus
apply side decodes up to **512**. Any id in (256, 512] is a silent asymmetry —
encodable by one path, over-cap for the other. Producers stay short today, so
no live crash — but this is exactly the interpretation drift the codec
extraction was meant to prevent.

**Fix:** make `consensus/envelope.zig` re-export the header primitives
(`encodeEnvelope` / `decodeEnvelope` / `encodeMulti` / `decodeMultiInner` /
`MAX_ID_LEN`) from `envelope_codec.zig`, keeping only the V2-spine additions
(`EntryFrame`, `Type`). `apply.zig` drops its `WriteSetPayload` copy and
re-exports the one canonical version (or `WriteSetPayload` moves down into
`envelope_codec.zig`, since it is std-only). One `MAX_ID_LEN`, one payload
codec. Both files already have round-trip tests, so this is mechanical.

### 1.3 `replay/tape_decode.zig` is a hand-synced duplicate tape decoder

`src/replay/tape_decode.zig` reimplements the entire tape binary format that
`src/tape/root.zig` already defines and parses:

- `MAGIC`/`VERSION` — `tape_decode.zig:14-15` hardcodes `VERSION: u16 = 5`
  with only a comment (`// src/tape/root.zig:82 (per-Tape)`) as the sync
  contract.
- Every entry type is redeclared as an independent copy: `Channel`, `KvOp`,
  `KvOutcome`, `KvPair`, `KvEntry`, `ModuleEntry`, `RequestReadKind`,
  `RequestReadEntry`, `FetchResponseEntry`, `TriggerPayloadEntry`, `Error`
  (`tape_decode.zig:17-89` vs `tape/root.zig:127-366`).
- Its `Reader` (`tape_decode.zig:94-138`) re-walks the same big-endian
  `[magic][version][channel][count]` header and length-prefixed entry loop
  that `tape/root.zig`'s `parse` (:1058) and `serialize` (:597) implement.

When someone bumps the tape wire format, nothing forces the replay decoder to
move with it — the `version != VERSION` guard will simply reject every
recorded tape at runtime, silently breaking `rewind pull`/replay with no
compile error.

**Fix:** make `tape/root.zig` the single source of truth — re-export `MAGIC`,
`VERSION`, `Channel`, and the entry structs from `tape_decode.zig`, and delete
the duplicate `Reader`/`decodeKv`/`decodeModule` in favor of `tape.parse`. At
absolute minimum, a `comptime` assert `tape_decode.VERSION == tape.VERSION`
removes the drift class for near-zero effort.

### 1.4 Dead code: `stageDeployment` is the pre-JS deploy path

`src/files/root.zig:539-602` (`stageDeployment`) plus its ~7 tests
(:1149–1245) is the old all-in-Zig deploy — validate paths, hash+PUT source
blobs, compile, compute the deployment id, encode + PUT the manifest — in one
call. The live path is `compileAndStage` (:627, correctly Zig: the slow
deterministic compile only) followed by `platform.deploy.stampManifest` in JS
(`src/js/globals/platform.js:98`); `compileAndStage`'s header even says "NO
manifest is written here; that's the JS deploy handler's job."

`stageDeployment` has no caller outside its own tests repo-wide (only a stale
comment at `src/js/deploy_thread.zig:413` and one in
`scripts/smoke/replay_wasm_smoke_v2.py:214`). It reads as authoritative but is
a corpse — a second, drifting deploy path.

**Fix:** delete (~160 lines incl. tests); fix the two stale comments.

---

## 2. The big unification: one outcome-finishing state machine

This is the highest-correctness-payoff refactor in the repo. The
"run handler → classify outcome (terminal/continuation/stream) →
propose-or-commit → resolve/park/teardown" state machine currently exists as
**three-plus implementations across ~11 call sites**, and it is precisely
where copies have drifted (§1.1 was one instance of the same disease).

### 2.1 The evidence

The docs claim (`docs/architecture/effects-and-handlers.md`) that
`Dispatcher.runOutcome` is "the single re-entry point for every activation."
That is TRUE at the engine level — there is no path that pokes
`snapshot.restore` and evaluates bytecode directly — but it is enforced only
by convention: the surrounding boilerplate is duplicated, not shared.

**(a) Five hand-rolled HTTP resume outcome-switches**, open-coding the same
terminal/continuation/stream classification:

- `resumeContinuation` — `worker_drain.zig:1384` (switch at :1561)
- `resumeBoundFetchChain` — `worker_drain.zig:1837` (switch at :2025)
- `resumeBoundContinuation` / inbound-chunk path — `worker_drain.zig:2334`,
  :3035 (runOutcome at :3194)
- `resumeStream` — `worker_streaming.zig:487` (switch at :639)
- `resumeBoundFetchStream` — `worker_streaming.zig:891` (runOutcome at :1062)

Compare the terminal arms: `worker_streaming.zig:640-649` vs
`worker_drain.zig:1562-1580` vs `worker_ws.zig:473-484` — the same
`if (r.exception.len > 0) { txn.rollback(); txn_done = true;
<site-specific teardown>; captureLogWithId(...500, .handler_error...);
return; }` shape, differing only in the teardown verb (`resolveParked` vs
`markStreamDraining` vs `tearDownWsChain`).

**(b) Eleven byte-identical `runOutcome(...)` invocation blocks.** The
11-argument call plus the same `catch { txn.rollback() catch {}; txn_done =
true; <resolve>; return; }`, then `worker_mod.noteChurnyOutcome(...)`, then
`const wrote = ws.ops.items.len > 0;` — see `worker_drain.zig:1542`, :2025,
:3194; `worker_streaming.zig:618`, :1062, :1502; `worker_ws.zig:643`; etc.
The args `(inst.kv, txn, &ws, bc, &tc.snap.bytecodes, &tc.snap.source_hashes,
&.{.triggers=…, .subscriptions=…}, req, &budget)` are the same expression
modulo `inst` → `p.dep.inst`. Today a new activation type can forget
`noteChurnyOutcome` (the inbound-chunk path at `worker_drain.zig:3194` nearly
does), silently disabling the churny-arena optimization.

**(c) The WS family already solved this.** `finishWsResume`
(`worker_ws.zig:447-570`) is shared by all four WS resume entry points
(`fireWsMessage` :643, `resumeBoundFetchChainWs` :843, `resumeWakeChainWs`
:946, and :1081). And `runFire` (`worker_streaming.zig:1465`) already
enumerates the per-firer behavior axes in a `FinishSpec` struct (:1378).
`runFire`, `finishWsResume`, and the five open-coded HTTP switches are three
implementations of one machine: terminal-with-exception → rollback + log 500;
terminal-with-writes → `proposeForgetfulWrites`; terminal-read-only →
commit + flush fetches; continuation/stream → re-park.

### 2.2 The refactor, staged

1. **`runResume` wrapper** — collapse the 11 invocation blocks into one
   `worker.dispatcher.runResume(dep, txn, &ws, req, &budget)` (or a `RunCtx`
   bundle) that also folds in the mandatory `noteChurnyOutcome`. Makes the
   "single re-entry point" doc claim structurally enforced at the call level.
2. **`finishHttpResume`** — mirror `finishWsResume` for the five HTTP resume
   switches, parameterizing the teardown/park verbs the way the WS one
   already takes its `act`/`tag`/`msg` triple. This is where the
   txn-ownership flags (`txn_owned`/`txn_done`) and the propose-vs-commit
   branch have drifted; consolidation removes the "one resume path forgot to
   rollback on the propose-error arm" bug class.
3. **`finishOutcome` core** (larger, last) — hoist the classification into
   one `finishOutcome(worker, &oc, FinishSpec, callbacks)` and express
   `runFire`, `finishWsResume`, and `finishHttpResume` as thin adapters
   supplying propose/teardown callbacks.

Warm-up bundled with step 2: `worker_drain.zig:1598-1609` and
`worker_streaming.zig:676-687` rebuild the terminal `LogHeader` literal
inline (10 fields each) while the WS path already uses the extracted
`worker_streaming.fireLogHeader` (:1401) — route the two inline literals
through it.

This arc touches the dispatch hot path; it wants its own branch with smoke
coverage (`rewind_smoke`, `three_node_smoke`, plus the WS smokes).

### 2.3 Wave-2 progress + the drift list (added 2026-07-08, branch `refactor/finish-outcome`)

Landed: step 1 (`worker.runResume`, all 11 sites) and the step-2 warm-up
(all 11 inline LogHeader literals → `fireLogHeader`). A full per-arm
variance pass over the five HTTP switches found the five sites split into
TWO families (cont-family: S1 `resumeContinuation`, S2
`resumeBoundFetchChain`, S3 inbound-chunk — `resolveParked` +
`proposeAndParkContResume`; stream-family: S4 `resumeStream`, S5
`resumeBoundFetchStream` — `markStreamDraining*` +
`proposeForgetfulWrites`), so step 2 is two shared finishers, not one.
Drifted arms found (fix as small commits BEFORE extracting):

1. **DONE** — cont-family dispatch-error + no-export arms logged nothing
   (six arms; stream/WS/fire all record a 500 `.handler_error`).
2. **DONE (user call, 2026-07-08: keep the binding)** — read-only reparks
   leave `bound_schedule_id` untouched everywhere; only a writing repark
   rewrites it. Clearing (old S2/S3) stranded a chain still awaiting an
   earlier hop's owed send. The `cont_bound_sched_id` doc-comment's
   "THIS hop" wording describes the writing-repark scan, not a
   per-hop-reset invariant.
3. **DONE** — OOM postures unified: pre-propose failure → rollback +
   defined 500 + log; post-commit failure → loud close without the
   final chunk (writes stay durable).
4. **DONE** — cont-family captures dropped `r.tags` (nine sites).
5. **DONE** — read-only repark hops logged at all three cont sites.
6. **DONE** — stream-family `tryAppend` unified on catch + loud (rode
   the #3 commit).
7. **OPEN, minor** — flushResumeFetches before (S1) vs after (S2/S3) the
   desc swap; S1's `scanLoneOwedSendId` dupe `try` vs S2/S3 `catch null`.
8. **Deliberate, keep** — resumes commit-or-panic on `error.Conflict`;
   `commitReadOnlyFire` tolerates it (fires run outside the chain lease).
   Document on the shared finisher.

**Extractions LANDED 2026-07-08:** `finishContResume` (worker_drain.zig —
S1/S2/S3, comptime spec {site, noun, cancel_binds, tape-kind}, the
`.stream` arm stays `resumeIntoStream`; −450 lines) and
`finishStreamResume` (worker_streaming.zig — S4/S5, draining unified on
`markStreamDrainingAnywhere`, the S5 ensure-then-assumeCapacity latent UB
closed; −330 lines). #7's minors normalized in the collapse. Found + fixed
along the way: the #3/#6 posture commit had added double-frees around
`tryAppend` (it frees its chunk on error — contract now documented at the
call sites). Note: `streaming_first_hop_writes_smoke_v2`'s onDisconnect
leg fails on main at `da7b26f` too (clean bisect) — pre-existing, not
from this branch.

**Step 3 (`finishOutcome` core) — RECOMMEND CLOSING as not warranted.**
The premise was three-plus drifting copies of one machine; after steps
1–2 each family's switch exists exactly once (`finishContResume`,
`finishStreamResume`, `finishWsResume`, `runFire`) and the cross-family
differences that remain are real semantics (park machinery:
`proposeAndParkContResume` vs `proposeForgetfulWrites` vs WS chains;
teardown: resolveParked vs draining vs tearDownWsChain), not drift. A
callbacks-core would abstract a ~30-line classification skeleton at the
cost of indirection across three files. The drift bug-class died with
the copies. Revisit only if a NEW activation family appears.

---

## 3. Cross-binary duplication (rewind / cp / front / log-server)

The four binaries grew by copy-paste from a common ancestor; the mechanical
scaffolding diverged only cosmetically.

### 3.1 Raft env parsing duplicated between worker and CP (correctness-grade)

`rewind/main.zig:502-551` (`parseMultiNode`) and `cp/main.zig:102-151`
(`parseCpMultiNode`) are the same ~50-line function with env names swapped
(`REWIND_VOTERS` → `REWIND_CP_VOTERS`, `REWIND_PEERS` → `REWIND_CP_PEERS`,
`MissingVoters` → `MissingCpVoters`). The backing structs are field-for-field
identical (`MultiNode`, `rewind/main.zig:474-490` vs `CpMultiNode`,
`cp/main.zig:75-91`). `parseGenesis` (`rewind/main.zig:573-589`) hand-rolls
the same `host:port` split a third time.

A bug in voter-set / peer-index parsing is a split-brain or
wrong-listen-address hazard, and today a fix must be mirrored across three
sites by hand.

**Fix:** `RaftClusterConfig.fromEnv(a, prefix)` in the bridge module, taking
the env prefix (`"REWIND_"` / `"REWIND_CP_"`), returning a shared `MultiNode`
(move it plus `PeerAddr` parsing into `consensus/`). `parseGenesis` reuses the
same `host:port` helper. Both call sites already pass identical option shapes
into `Bridge.initMultiNode`, so this is pure extraction.

### 3.2 Boot scaffolding copy-pasted 4×

- **Signal handling** — `handleSignal`/`installSignalHandlers` byte-identical
  in `rewind/main.zig:49-61`, `front/main.zig:59-71`, `cp/main.zig:56-68`,
  `log_server/main.zig:40-75`.
- **`parseUrlList`/`freeUrlList`** — identical in `rewind/main.zig:593-611`,
  `front/main.zig:349-367`, `cp/main.zig:1802-1822`.
- **Operator-metrics boot block** — the same
  `getenv → parseInt(default) → 0 disables → parseIp("127.0.0.1") →
  MetricsServer.init → warn-on-bind-fail` block in `rewind/main.zig:954-964`,
  `front/main.zig:706-719`, `cp/main.zig:2118-2131`,
  `log_server/main.zig:309-319`. Only the default port differs
  (9110/9111/9112/9113 — each file carries a comment manually tracking the
  other three to avoid collision).
- **`rove.logNonBlocking()` + `std.heap.c_allocator` preamble** with the same
  multi-line justification comment (`rewind/main.zig:642`,
  `front/main.zig:488`, `cp/main.zig:1905`).
- **Publish-metrics-every-2s cadence** inline in three poll loops
  (`rewind/main.zig:367-376`, `front/main.zig:743-751`,
  `cp/main.zig:2160-2169`) and as a thread in the fourth
  (`log_server/main.zig:53-65`).

**Fix:** a small `src/boot/root.zig` (`rove-boot`):
`installSignalHandlers(*stop_flag)`, `parseUrlList`/`freeUrlList`, and
`MetricsListener.fromEnv(a, env_name, default_port)` owning the bind plus a
`maybePublish(now, render_fn)` gate. The four default ports become named
constants in one table so the coexistence invariant lives in one place.

### 3.3 Writer/reader wiring that MUST agree, duplicated (correctness-grade)

Two independent copies of the "load hex HMAC secret" routine:
`rewind/main.zig:716-728` and `log_server/main.zig:169-189` — same
even-length-hex → `hexToBytes` → `exit(2)` logic. And the S3 `BatchStore`
construction from a blob cfg is verbatim in both — `rewind/main.zig:885-898`
and `log_server/main.zig:233-246`:

```zig
const key_prefix = (try blob_mod.env.envOpt(allocator, "LOG_S3_KEY_PREFIX")) orelse try allocator.dupe(u8, "");
var s3_handle = try log_server.batch_store_s3.S3BatchStore.init(allocator, .{
    .endpoint = cfg.endpoint, .region = cfg.region, .bucket = cfg.bucket,
    .key_prefix = key_prefix, .access_key = cfg.access_key,
    .secret_key = cfg.secret_key, .use_tls = cfg.use_tls });
```

The worker (writer) and log-server (reader) MUST agree on endpoint/prefix or
captured tapes are unreadable — a hazard `rewind/main.zig:874-884` documents
at length while leaving the agreement to hand-synced code.

**Fix:** `jwt.loadSecretFromEnv(a, var_name)` in `rove-jwt`, and
`log_server.batch_store_s3.fromBlobCfg(a, cfg)` reading `LOG_S3_KEY_PREFIX`
once. Both binaries call the same two functions; agreement becomes
structural.

### 3.4 Five hand-rolled h2 reply helpers

The h2 response idiom — `reg.set(Status) → set(RespHeaders) → set(RespBody) →
set(H2IoResult) → set(StreamId) → set(Session) → reg.move(request_out →
response_in)` — is copy-pasted as private helpers in every HTTP-serving
surface:

- `cp/main.zig:255-275` (`replyStatus`, `replyText`)
- `front/main.zig:232-271` (`replyStatus80`, `replyFull`) +
  `packRespHeader` (:245)
- `front/proxy.zig:2391` (`replyStatus`)
- `log_server/standalone.zig:902-963` (`setResponse`, `setResponseOwned`,
  `setPreflight`) + `packHeaders` (:871)

Same six `set` calls in the same order; variation is CORS headers
(log-server) and a header set (front). `packRespHeader` (single header) and
`packHeaders` (N headers) are the same buffer-packing routine at different
arity — and `js/response_builder.zig:63` (`packRespHeaders`) is a third copy.

**Fix:** promote a `reply` helper into `rove-h2` itself (it already owns all
the component types and the move collections):
`h2.reply(server, ent, sid, sess, .{status, headers, body})` plus one
canonical `packHeaders(a, []HdrPair)`. The "forgot to set H2IoResult / forgot
the move" bug class becomes unrepresentable.

### 3.5 Per-surface request-dispatch plumbing

Each serving binary hand-writes the same poll-loop tail
(`pollWithTimeout → processRequests → reg.flush → cleanupResponses →
reg.flush`: `cp/main.zig:2140-2148`, `log_server/standalone.zig:208-214`,
`front/main.zig:799-812`), the same `cleanupResponses`
(`front/main.zig:205-208`, `cp/main.zig:1791`,
`log_server/standalone.zig:225-228`), the same `headerValue` linear scan
(`cp/main.zig:161-172`, `front/proxy.zig:160-172`, inlined in the others),
and the same query-string splitters (`cp/main.zig:1781`,
`log_server/standalone.zig:991-1022`).

**Fix:** a thin `h2.RequestCursor` over `request_out` (`method()`, `path()`,
`header(name)`, `query(key)`, `body()`) plus a
`serviceRequests(server, ctx, handlerFn)` owning the flush/cleanup dance.
The three `processRequests` bodies become pure `switch (path)` routers.

### 3.6 `cp/main.zig` Router is five subsystems in one struct

The single `Router` struct (`cp/main.zig:199-1780`, ~1,580 lines) carries:

1. **Read API** — `/_cp/route|plan|cert|certs|leader|acme-challenge`
   (`handleCp` :321 …).
2. **Control-write API** — `/_control/*` (`handleControl` :490 through
   `handleCert` :829), incl. follower→leader forwarding
   (`forwardControlToLeader` :921).
3. **Move orchestration** — `handleMoveLive` :1134, `findDestLeaderUrl`,
   `streamMergeToAll`, `snapshotPushToLeader`,
   `forwardBeginOnLeader/EndOnLeader` (:1234–1342).
4. **Membership reconciler** — `ensureMember` :1400, `reconcileConfChange`,
   `bootstrapMember`, `demoteGrace*`, the RC-6 hysteresis state
   (:1343–1726, self-contained test at :2176).
5. **HTTP transport** — `backendCall`/`backendCallTimeout` (:1727–1779) +
   reply helpers.

The reconciler and move orchestrator never touch the read-API state, yet all
share one struct and file.

**Fix:** extract `cp/reconciler.zig` (state machine + hysteresis + its test —
it already keys everything on `tenant|node_id`), `cp/move.zig` (move
orchestration; helpers already take explicit `nodes`/`tenant` args), and
`cp/backend_client.zig` (`backendCall*`, `BackendResp`, move-secret header).
`Router` shrinks to routing + read API + directory writes.

### 3.7 `front/proxy.zig` split

One 3,233-line file, one god struct plus three fat inline sub-structs; the
code's own `── section ──` banners already mark the cleavage lines:

- **`Flow`** (:739–868) — ~130 lines of fields spanning observability,
  forwarding identity, request-body replay buffer, route-park, upstream
  attempt (421 re-aim: `saw_421`, `canRetry` :865, `reconnect_budget`), and
  response relay.
- **`Upstream`/`Leg`** (:649–686) — the connection pool (least-loaded pick,
  backoff/deadline, `n_legs` growth) + `poolEntry` :1603 + the connect-result
  handlers (:1866) + `expireStalledConnects`.
- **`WsTunnel`** (:693–733) — the h2c Extended-CONNECT tunnel leg
  (:1057–1415) — orthogonal to request proxying; shares only the pool.
- **Backpressure** — `down_drained`/`up_drained`/`resp_drained`
  window-repayment and the `*SinkPush` callbacks (:2542–2604), threaded
  through all three.

**Fix:** split into `proxy/pool.zig`, `proxy/ws_tunnel.zig`, and (already
cleanly separable) `proxy/route_cache.zig` for `RouteCache`/`LeaderCache`
(:339–524); `Flow` + intake + response relay stay in `proxy.zig`. Sub-structs
currently reach into `*Self` for counters — those become passed-in refs.

Verified non-finding: the proxy does NOT duplicate `h2/root.zig` — the
client-leg mechanics (stream submission, early header emit, body sink, idle
reap, window auto-update) live in h2 and the proxy drives the public API.
The one candidate to push down is per-leg inflight accounting + stream-cap
shed (`Leg.inflight` :661, `leg_stream_cap`), which is generic client
multiplexing bookkeeping.

### 3.8 Five one-shot CP-lookup HTTP clients

The "GET a small control-plane JSON from the first reachable CP node" pattern
(`curl.Easy.init → request(h2c_prior_knowledge, verify_tls=false) → check
status → dupe body`) is copy-pasted at:

- `front/main.zig:89-110` (`CertSync.cpGet`) and :275–298
  (`acmeChallengeLookup`)
- `log_server/standalone.zig:312-328` (`fetchRetentionNs`)
- `cp/main.zig:1743-1779` (`backendCallTimeout`, the server-side twin)
- `cli/rewind.zig:102` (`httpCall`) + `cpOp` :342 (comment at :335 admits the
  shapes "mirror the CP routes")

**Fix:** `blob.curl.cpGet/cpPost(a, cp_urls, suffix, opts)` — first-reachable
iteration + owned-body return. Secondary benefit: the `verify_tls=false`
default becomes one auditable knob instead of five.

---

## 4. h2 / io layer

`src/h2/root.zig` (5,876 lines) is: leaf types (:17–690) + one giant generic
runtime struct `H2(comptime opts)` (:795–5791) + tests. The TLS / h1-parse /
WS-framing primitives already live in siblings (`tls.zig`, `http1.zig`,
`ws.zig`); this file is the runtime gluing nghttp2 + those codecs onto
rove-io. Main structs: `Conn` (:175, 12 fields), `Http1Conn` (:250, **29
fields**), `Stream` (:442, ~30 fields), and the runtime struct itself (27
collection fields + ~15 scalars).

### 4.1 `Http1Conn`: 29 fields, four mutually-exclusive lifecycles

The fields fall into four disjoint phases, which the comments themselves call
mutually exclusive (:335: once `ws_mode` is set "the connection has left the
HTTP request/response model"):

- h1 request/response (`buf`, `in_flight`, `keep_alive`, `closing`,
  `chunk_body`, `chunk_pos`, `continue_sent`, `streaming`, `sending_entity`)
- h1 inbound-body streaming (`stream`, `body_active`, `body_remaining`,
  `body_chunked`, `body_seen`, `expect_continue`, `paused_read`)
- WS framed mode (`ws_mode`, `ws_msg`, `ws_msg_opcode`, `ws_out`,
  `ws_write_inflight`, `ws_closing`, `ws_authority`, `ws_path`)
- WS upgrade surface / raw tunnel (`ws_pending`, `ws_key`, `tunnel_sink`,
  `tunnel_unconsumed`)

Nothing in the type prevents `body_active && ws_mode`, or `tunnel_sink` set
mid-body.

**Fix:** `Http1Conn = struct { allocator, buf, state: union(enum) { http1,
ws_framed, ws_tunnel, ws_pending } }`, hoisting only the genuinely shared
fields. Illegal cross-phase combinations become unrepresentable, and `free`
(:394) matches on the arm instead of conditionally freeing 7 optionals.

### 4.2 h1 and h2 hand-roll the same header-buffer packing

Both paths pack a `HeaderField[]` array + name/value string blob into one
combined allocation and hand it to the same `ReqHeaders` setter:

`Stream.hdrFinalize` (:589):

```zig
const fields_size = @as(usize, n) * @sizeOf(HeaderField);
const total = fields_size + self.hdr_strbuf_len;
const buf_slice = self.allocator.alloc(u8, total) catch return null;
const strbuf_base = buf_ptr + fields_size;
```

`http1BuildReqHeaders` (:4184):

```zig
const fields_size = n * @sizeOf(HeaderField);
const total = fields_size + strbytes;
const buf = try self.allocator.alloc(u8, total);
const strbase = buf.ptr + fields_size;
```

The correctness weight is high: the h2 growth paths carry two remote
heap-overflow hardenings (`hdrAppend` comment :548 "h2spec http2/6.10",
`bodyAppend` :610); the h1 copy can drift out of sync with the hardened one.

**Fix:** extract a `HeaderBuf` builder (`append(name, value, lower_name)` →
`finalize() []owned` producing the `{fields|strbuf}` layout); both
`hdrAppend`/`hdrFinalize` and `http1BuildReqHeaders` call it.

### 4.3 Two independent RFC 6455 reassemblers

WS fragmentation/continuation reassembly exists twice: `WsReassembler`
(:411, WS-over-h2 via `Stream.ws_reasm`, driven by `wsStreamDrive` :1606)
and, inline, `Http1Conn.ws_msg`/`ws_msg_opcode` (:352) driven by
`wsDrive`/`wsHandleFrame` (:4657/:4700). Two copies of the fragmentation
state machine = two places for a continuation/opcode-tracking bug — a classic
WS security surface.

**Fix:** promote `WsReassembler` to the single reassembler
(`feed(frame) → ?Message`); the h1 path holds one inside its `WsFramedState`
arm (folds into §4.1).

### 4.4 Duplicated inbound-body routing on a deliberately shared accumulator

The design already shares the `Stream` accumulator across protocols
(`Http1Conn.stream` comment :297), but the dispatch on top is duplicated:
`flipInboundBodyToDiscard` (:3014, h2) vs `http1FlipInboundToDiscard`
(:4020, h1); the `.hold/.buffer/.discard/.sink` routing in
`onDataChunkRecvCb` (:1776) vs `http1RouteBody`/`http1DriveBody`
(:3909/:3856).

**Fix:** lift the routing into `Stream.route(bytes, body_mode) →
RouteOutcome` (append-or-drop + window repayment amount), leaving each
protocol only its transport-specific repayment (`nghttp2_session_consume` vs
socket-read unpark). Removes the twin `*FlipInboundToDiscard` pair.

### 4.5 Group the runtime struct's 27 flat collection fields

(:829–975) — group into `server`, `client`, `ws`, `metrics` sub-structs. The
comptime collection-registry loop (:998) already treats them uniformly, so
this is low-medium effort; documents which poll phase touches which group.

### 4.6 File split for `h2/root.zig`

- Zero-risk first step: move the non-generic leaf types (`Stream`,
  `Http1Conn`, `Conn`, `WsReassembler`, `BodyData`) into `conn_state.zig`
  (~450 lines out).
- Then the generic method groups via the mixin pattern
  (`fn Http1Methods(comptime Self: type) type`) in `runtime_h1.zig`
  (25 fns, :3595–4439), `runtime_ws.zig` (36 fns, :1446–1739 + :4439–4792),
  `runtime_client.zig` (:5400–5791) — ~2,500 lines out; root keeps the
  struct, the poll loop, and the nghttp2 server callbacks.

Do §4.1 first — it shrinks the biggest struct that would otherwise move.

### 4.7 raft_net vs rove-io: bypass stays; extract two tiny helpers

The two io_uring users are genuinely different (rove-io: multishot accept,
direct FDs, buffer-ring reads, ECS collections, no reconnect; raft_net:
classic accept, fixed per-peer buffers, static `peers[]` mesh with IDENT
identity, exponential-backoff reconnect) and the disjoint-mesh design is
documented (`docs/architecture/raft-native-alignment.md`). **Do not unify.**
Worth extracting anyway:

- an **`OrderedSendQueue([]u8)`** ("exactly one write in flight + FIFO owned
  buffers": `Peer.send_queue` `raft_net:159-200`, `Conn.send_queue` /
  `send_inflight` `h2:214-215`, `Http1Conn.ws_out`/`ws_write_inflight`
  `h2:358-360`) — three copies of the same ownership/free contract;
- optionally a shared io_uring `user_data` tag codec (`io/root.zig:222-230`
  vs `raft_net.zig:122-134`) if touching the above.

---

## 5. Consensus / KV

Verified clean (no action): `kvlimbs.zig` is a pure re-export seam;
`apply.zig` is a thin wrapper over the shared codec except the §1.2 copy;
`directory.zig` correctly reuses the bridge (registers one group, injects an
apply observer — no per-group machinery reimplemented).

### 5.1 `Bridge`: extract the ControlCmd relay (`bridge_control.zig`)

`ControlCmd` (`bridge.zig:197-260`) is a 60-line union-of-all-payloads with
15 `Kind` variants and mutually-exclusive fields, driven by ~15 near-identical
2–3-line public wrappers (`createGroupEpoch` :962 … `applyLocalSnapshot`
:1145), all funneling through `runControl` (:1153) and a **148-line**
`drainControl` switch (:1167–1315). The subsystem is self-contained (touches
only `self.node.*` + `control_inbox`/`mutex`).

**Fix:** move `ControlCmd` + `runControl` + `drainControl` + the wrappers to
`src/consensus/bridge_control.zig` (~450 lines out of `bridge.zig`),
isolating the "Manager is pump-thread-only, so everything is a blocking RPC
to the pump" pattern in one place. Follow-up: the worker↔pump SPSC queues
(`control_inbox` :394, `wake_inbox` :404, `fault_requests` :409, `promoted`
:378, `snapshot_catchup` :383, `catchup_inflight` :390) all share the
"worker enqueues, pump drains" shape and could share a typed-queue helper.

### 5.2 `Node`: PeerRegistry out; ActiveSet + ApplyPolicy extractions

- **`PeerRegistry`** (`node.zig:73-160`) is a complete, self-contained
  id→address map that has nothing to do with `Node` (it is injected into the
  Transport; the Bridge owns an instance). Move to
  `consensus/peer_registry.zig`. Trivial; do first.
- **`ActiveSet`**: the Phase-6 hibernation machine is smeared across `Node`
  (`active` :495, `hibernate_ns` :620, `leaderless_escalate_ns` :629,
  `woke_scratch` :633, auto-demote fields :522–526) and `TenantSlot`
  (`active_until_ns` :413, `in_active` :416, `pinned` :422,
  `leaderless_since_ns` :444), with methods `bumpActive` :1407, `pinActive`
  :1423, `dropActive` :1435, `sweepHibernated` :1449, `escalateLeaderless`
  :1490. Extract `consensus/active_set.zig` owning the list + timing knobs,
  with a per-slot `slot.hib` sub-struct. The hibernation invariants ("bump on
  propose + non-heartbeat step", "pinned never sweeps", "leaderless
  escalation cooldown") currently live as scattered comments across 200
  lines. Note the `in_active`/`in_dirty`/`in_persist_ack` dedup-bit pattern
  repeats 3× on `TenantSlot` — centralizing one documents the pattern.
- **`ApplyPolicy`**: `Node` carries six optional injected hooks that are all
  set together by the bridge and jointly define "how does a committed entry
  apply here": `commit_hook` :585, `skip_query` :591, `durabilize_floor`
  :596, `apply_observer` :608, `apply_mode` :616, `store_resolver` :639 —
  consulted as a group in `applyEntry` :1997 / `storeFor` :2105 /
  `notifyApply` :2119. Six independently-nullable fields invite "set 4 of 6"
  bugs. Fold into one `apply_policy: ApplyPolicy` struct set atomically; the
  two legal configurations (bare-node vs worker-overlay) become explicit.

### 5.3 File splits for `node.zig` / `bridge.zig`

After §5.1/§5.2, `node.zig` (3,255) splits along its function outline:

1. `node_groups.zig` — group lifecycle (`ensureGroup` … 
   `destroyGroupAndReclaim`, :813–1358): manifest + `GroupedFileStorage`
   standup/teardown.
2. `node_membership.zig` — membership & introspection (:1132–1308), the
   pump-side twins of the bridge's ControlCmd relay.
3. `node_pump.zig` — `pump`/`durabilizeTick`/`autoDemoteTick`/`markDirty`/
   `applyCb`/`applyEntry`/`storeFor`/`notifyApply`/`sendMsgCb`
   (:1580–2161), the hot loop.

`bridge.zig` similarly: `bridge_control.zig` (§5.1) + `bridge_pump.zig`
(`pumpLoop`/`pumpOnce`/`snapshotTriggerTick`/`refreshLeadership`/
`sweepLostLeadership`, :1350–1721), leaving init + tenant/propose + commit
hooks.

### 5.4 Lower priority / awareness

- `directory.zig`'s six write axes (`addCluster` :562, `assign` :620/:648,
  `setPlan` :733, `setHost` :778, `setCert` :855, `setNodeAddr` :990) each
  hand-roll the same "build `{prefix}/{id}` key, format value,
  `applyDirWrite`" shape plus a mirror `applyXLocal` and a branch in the
  prefix router (:527–541). A `{prefix, pack, applyLocal}` axis table would
  collapse six near-identical pairs. Clarity-only; skip unless in the file.
- The baseline `{index, term}` snapshot-bundle protocol ("read baseline →
  `v2-snapshot` dump → `v2-load-replace` → `v2-apply-snapshot`") is
  duplicated between `v2_move.zig` (worker side) and `cp/main.zig:1634`
  `bootstrapMember` (CP side). Cross-repo-area; flag for the §3.6 extraction.

---

## 6. JS worker cluster (`src/js`)

Scope note: the `Dispatcher` struct itself (`dispatcher.zig:119`) is NOT a
god struct (5 fields). The god struct is **`Worker`** (`worker.zig:1324`, the
comptime factory's `return struct`) with ~76 fields. `NodeState`
(`worker.zig:848`) already demonstrates the cure — it decomposed into
`DeploymentCache`, `MsgRouter`, `BlobCoordination` sub-structs.

### 6.1 `dispatcher.zig` is 86% test code

7,028 lines; the first `test` is at line 950 and 152 tests + fixtures
(`PlatformFixture` :5824, `DeployStarterRecorder` :5965) run to EOF. There is
no `pub` declaration after line 950. Move everything from :950 to EOF into
`dispatcher_test.zig` (wire into the build graph's test step; a handful of
private helpers need `pub` or a test-only re-export). Highest
clarity-per-effort in the subsystem; near-zero risk.

### 6.2 `Worker` field extractions

- **`LogSubsystem`** (18 fields): `tenant_logs` :1716, `log_buffer` :1721,
  `log_records_dropped_total` :1662, `log_worker_id` :1751,
  `last_uploaded_seq` :1762, `log_batch_store` :1774, `log_public_base`
  :1786, `log_push_bases` :1789, `files_public_base` :1790,
  `internal_insecure_tls` :1793, `log_push_curl` :1798, `flusher_thread`
  :1808, `flusher_should_stop` :1809, `flusher_wake` :1810, `push_queue`
  :1820, `push_queue_mutex` :1821, `push_wake` :1822, `push_should_stop`
  :1823, `push_thread` :1824. The behavior already lives in
  `worker_log.zig`; bundling the state gives it a self-contained
  `init`/`deinit`, making the "join threads before freeing `push_queue`"
  ordering local and auditable.
- **`SpoolRegistry`** (9 fields): `bound_fetch_entities` :1576,
  `bound_fetch_spools` :1609, `coord_pending_releases` :1619, the four
  depth/peak/readback/dropped counters :1626–1653, `bound_send_entities`
  :1681 — driven by `worker_streaming.zig`'s
  `pushToSpool`/`dispatchSpoolHead`/`drainSpools`/`dropSpool`. Tightens the
  invariant that keys in the three separate hash maps are freed together
  (currently three separate spots in `destroy`).

### 6.3 File splits

- **`worker_streaming.zig`** (3,433): its own header (:1–35) lists four
  concerns — (a) stream lifecycle (:82–891), (b) activation firers +
  `firePrep`/`runFire` scaffold (:1279–2255, :3234+), (c) commit-gated
  buffer `proposeForgetfulWrites`/`fireKvReactSubscriptions` (:2256–2528),
  (d) Msg ingress + spools (:2653–3260). Cleanest extraction: the firer
  family → `worker_fire.zig` (note `worker_ws.zig` imports `fireLogHeader`,
  `synthCtxBody`, `proposeForgetfulWrites` — keep `pub`). Spools move with
  §6.2's `SpoolRegistry`. Do after §2 so the firer/resume boundary is clean.
- **`worker_dispatch.zig`** (4,205): ~1,300 lines are the `/_system/*` admin
  surface (`tryHandleSystem` :1045, `authorizeSystemRequest` :1242,
  `handleServicesTokenMint` :1285, `handleMetrics`/`buildMetricsText`
  :1340/:1360, the four metrics text-writers :1567–1704, `handleRaftSnapshot`
  :1753, `handleRelease` :1839, `handleReset` :2079, `handleAdminKv` :2121)
  — a distinct concern from the hot dispatch path. Move to
  `worker_system.zig`; they already take `worker: anytype`, so cross-ref
  cost is low. Leaves the file focused on
  `dispatchOnce`/`finalizeBatch`/`resolveRequest`.
- **`globals.zig`** (3,640): three cohesive clusters — kv surface
  (`jsKv*` + size/reserved-key guards, :671–1191), platform admin surface
  (`jsPlatformRoot*`/`jsScope*`, :1302–1956), request surface
  (`installRequest` + headers/cookies/ip getters + `deriveClientIp`/
  `maskIp`/`parseCookies`, :2423–3425) → `globals_kv.zig` /
  `globals_platform.zig` / `globals_request.zig`, with `install` /
  `installStatic` and the shared `DispatchState` accessor (:664) staying as
  the assembly root. Navigability win; also separates customer-facing kv
  from privileged `platform.root.*` ops.

(§2 covers the finishOutcome/runResume unification, which is the
correctness-bearing item in this subsystem.)

---

## 7. Storage leaves (blob / files / tenant / log-server)

### 7.1 Two SigV4 S3 clients

`log_server/batch_store_s3.zig:3-5` states it itself: "Parallels
`src/blob/s3.zig` — same SigV4 plumbing — but exposes the `BatchStore` vtable
instead of `BlobStore`." Both wrap `sigv4` + `curl` and each grows its own
sign-and-dispatch core (`s3.zig:322 requestAlloc` / `:664 requestExt` vs
`batch_store_s3.zig:311 requestAlloc` / `:379 dispatchSigned`), each with a
locally-declared `HttpResp`. They diverge only at the verb edges
(`batch_store_s3`: `vGetRange` :159, `vList` :197 + `parseKeysFromXml` :460;
`s3.zig`: multipart :431–496, `presignGet` :263, `copyObject` :563). The
vtables are near-parallel too: `blob/root.zig:80 BlobStore` (put/get/delete)
vs `log_server/batch_store.zig:49 BatchStore` (put/get/getRange/list).

**Fix:** extract a `SignedS3Client` in `blob/` (endpoint config + `EasyPool`
+ one `requestAlloc(method, key, body, extra_headers, query) → HttpResp`);
both stores compose it, keeping only verb-specific methods and their vtable
adapters. `BatchStore` becomes `BlobStore` + `{getRange, list}`.
`putWithRetry` (`coordinator.zig:1032`, a generic bounded-backoff-on-SlowDown
helper) belongs here too.

### 7.2 `curl.zig` vs `curl_multi.zig`

Confirmed: `curl.zig` is the sync easy-handle wrapper (`Easy`/`EasyPool`,
used by s3/ACME), `curl_multi.zig` the async event-loop wrapper
(`Transfer`/`Multi`, used by `fetch_engine`/`proxy_engine`). They do not
layer; each re-implements the wiring:

- Value types duplicated: `Method` (curl :34 vs multi :58), `Header`
  (:52/:60), `Request` (:105/:70), `Error` (:28/:51), `BodyCursor`
  (:697/:130).
- Option wiring duplicated line-for-line (:216–286 vs :192–282): URL `dupeZ`,
  headers slist build, the method switch
  (HTTPGET/NOBODY/UPLOAD/POST/CUSTOMREQUEST), TLS-verify + timeout opts.
- Callbacks duplicated: `readBody` (:702) == `readBodyCb` (:573); the
  header-line parser is verbatim (`headerResp` :810 vs `writeHeaderCb` :522).

**Fix:** `curl_common.zig` — shared types + `applyRequestOpts(handle, req)` +
`readBody` + `parseHeaderLine`. Keep BOTH execution models (do not delete
`curl.zig`: connection-cached blocking calls without an event loop are a real
need, and faking sync over Multi is a worse abstraction). ~150 shared lines
extracted; kills the "header-parse fix lands in one copy" risk.

### 7.3 `BlobCoordinator`: extract the reservation allocator

`coordinator.zig:256-321` (~28 fields) mixes four clusters: submission
queueing, executor/upload, retained-batch dereference, and the raft
id-reservation refiller. The last is a self-contained second machine — nine
fields (`res_mu`, `res_id_avail`, `res_refill_cond`, `current`, `upcoming`,
`refill_needed`, `refill_in_progress`, `prev_committed_end`,
`local_batch_ctr`) + `refill_thread` + `refillLoop` (~:914) — that never
touches bytes.

**Fix:** `ReservationAllocator` struct exposing `nextBatchId() Error!u64`.
Coordinator drops to ~19 fields; the double-buffered `current`/`upcoming`
refill (the trickiest concurrency in the file) gets a testable seam.

### 7.4 Shared `listUnderPrefix` KV helper

Five copies of the "scan a prefix, strip `prefix.len`, iterate" loop:
`tenant/root.zig:492` (`listInstances`), :523 (`listDomains`), :350
(deleteInstance domain sweep), `files/root.zig:255` (`clearFileEntries`),
:430 (`assembleManifest`). `KvStore` only exposes the raw iterator
(`kvstore.zig:663`). One `listSuffixes(prefix, max, alloc) → [][]const u8`
helper removes five off-by-one-prone slice strips. Low stakes, low effort.

---

## 8. Zig→JS: no new lifts; JS-side dedup remains

The lift-effect-composing-Zig-into-JS direction (decisions §3.3,
effect-algebra §5) is **already substantially executed**: webhook / email /
retry / schedule / cron / blob (all but presign) / the deploy pipeline (a
`__admin__` JS app over `platform.compile` + `blob.put` +
`deploy.stampManifest`) / the static cold path (`__system/static.mjs`) are
all JS composed over primitives. Every remaining Zig binding was checked and
fails the lift test for documented reasons — keep all of these:

| Candidate | Why it stays Zig |
|---|---|
| `bindings/http.zig` | the one outbound primitive + SSRF gate (wire) |
| `bindings/blob.zig` `presign` | S3 SigV4 keys = trust boundary (crypto) |
| `bindings/scheduler.zig` | the two capability-scoped durable-wake primitives; queue/backoff already JS |
| `bindings/on.zig` / `continuation` / `stream` | connection-scoped — no addressable handle in JS by construction |
| `bindings/email_rate.zig` | emission budget = resource bound → engine cap (a forkable JS limiter is not a limiter); node-ephemeral cross-request state |
| `acme/` | every hop is a JWS ES256 signature (crypto); leader-only CP infra; no tenant surface |
| `worker_log.zig` flush/push | cross-tenant node-local ephemeral buffer; no tenant activation to host it |
| `response_builder.zig` static serve | deliberately hybrid: LRU-hit native (hot path), miss → `__system/static.mjs` — the lift already happened for the cold path |
| `globals.zig`, `v2_move.zig`, `deployment_cache.zig` | isolation / wire / tape / privilege substrate |

The only Zig deletion is §1.4 (`stageDeployment`, dead). What remains is
**JS↔JS dedup** inside `src/js/globals/`:

- **Time coercion is triplicated**: `cron.js:44-56` `toFireAtNs` +
  `:241-254` `_parseDuration`; `schedule.js:103-130` `_coerceAt`/`_coerceIn`;
  `webhook.js:206-215` inlines its own `{at}`/`{in}` resolution. Three
  subtly-different edge cases (e.g. `_coerceAt` throws on bad ISO,
  `toFireAtNs` falls through). One `time.toNs({at}|{in})` library.
- **`base64url(sha256(x))` id idiom ×~5**: `webhook.js:199`,
  `schedule.js:73-75`, `cron.js:327`, `oidc.js:62`, `oauth.js:103`. One
  exported helper on the `crypto` shim.
- **Auth shims**: `oidc.js` (provider) and `oauth.js` (client) are
  complementary halves — do NOT merge — but they duplicate JWKS verification
  (`oauth.js:362 _verifyWithJwks` should delegate to `jwt.js:81 verify` /
  `:149 _selectJwk`), PKCE S256 (folds into the id-idiom helper), and cookie
  parse/build (`sessions.js:183/:200` vs oidc's session-cookie handling).
  Extract a shared authkit (JWKS-verify + PKCE + cookies) consumed by
  `oidc`/`oauth`/`sessions`. These are the security-sensitive shims; dedup
  carefully, with the surface-test suite as the gate.

---

## 9. Verified non-findings (don't spend time here)

Recorded so the next audit doesn't re-chase them:

- **`front/proxy.zig` does not duplicate `h2/root.zig`** — it is a proper
  consumer of the public client API; only per-leg inflight accounting is a
  push-down candidate (§3.7).
- **The raft_net io_uring bypass of rove-io is justified** — genuinely
  different models (static mesh + reconnect/backoff vs buffer-ring ECS);
  documented as deliberately disjoint. Only the small helpers in §4.7 are
  worth sharing.
- **`kvstore` ↔ `kvlimbs` layering is clean**; `kvlimbs` is a documented
  module-boundary re-export seam doing zero work of its own.
- **`apply.zig` is already thin** over the shared codec, except the §1.2
  payload-codec copy.
- **`directory.zig` reuses the bridge correctly** — no per-group machinery
  reimplemented.
- **`v2_move.zig` vs node snapshot/conf-change is not duplication** — the
  move code calls into the bridge relay; only the cross-file baseline
  snapshot-bundle protocol is shared with `cp/main.zig` (§5.4).
- **The ECS `Registry` (`rove/registry.zig`) is cohesive** — ~660 of 1,437
  lines are tests; the lifecycle-context registry is ECS-adjacent, not
  unrelated machinery.
- **log-server `main.zig` vs `standalone.zig` is not a near-copy** — main is
  thin arg/env wiring delegating to `standalone.spawn`. The log-server is
  the cleanest of the four binaries.
- **The "log/bodies/tape all batch to S3" hypothesis is obsolete** —
  `bodies/root.zig` is wire-format types only (the buffer moved into
  `BlobCoordinator` in Phase 3/5); tapes ride inline in log records
  (`log/root.zig:198 TapePayloads`). The two surviving batch engines
  (`blob/coordinator.zig` vs `log_server/flush_writer.zig`) legitimately
  differ in payload, keying, retention, and process — no shared batch-store
  extraction warranted beyond §7.1.

---

## 10. Sequencing

Grouped so each branch is independently landable and testable. Ordering
within a group is by (clarity × correctness-risk-reduction) / effort.

**Wave 1 — correctness quartet + near-free extractions** (small,
independent, no behavior change beyond the §1.1 fix). **DONE 2026-07-08**,
one commit per item on this branch; §1.3 landed as comptime/test lockstep
enforcement instead of the re-export inversion (replay_mod's
self-containment is deliberate — the CLI must not link rove-tape):

1. §1.1 `bridge.awaitCommit` (fixes the fault gap)
2. §1.2 envelope codec unification (one `MAX_ID_LEN`)
3. §1.3 tape decoder re-export (+ comptime version assert at minimum)
4. §1.4 delete `stageDeployment`
5. §6.1 dispatcher test split
6. §3.1 `RaftClusterConfig.fromEnv`
7. §3.2 `rove-boot` + §3.3 JWT/S3 wiring constructors
8. §5.2 `PeerRegistry` move

**Wave 2 — the finishOutcome arc** (§2, own branch, dispatch hot path;
gate on `rewind_smoke` + `three_node_smoke` + the WS smokes):
runResume wrapper → finishHttpResume → finishOutcome core.

**Wave 3 — illegal-states + hardened-code dedup in h2**:
§4.1 `Http1Conn` tagged union → §4.3 single WS reassembler →
§4.2 `HeaderBuf` builder → §4.4 body routing → §4.5/§4.6 grouping + split.

**Wave 4 — god-struct decompositions**, opportunistically, each its own
branch: §3.6 CP Router split; §6.2 Worker `LogSubsystem`/`SpoolRegistry`;
§5.1 `bridge_control.zig`; §5.2 `ActiveSet`/`ApplyPolicy`; §5.3 node/bridge
file splits; §3.7 proxy split; §7.3 `ReservationAllocator`; §6.3
worker_streaming/worker_dispatch/globals splits.

**Batch when touching those files**: §3.4 `h2.reply`, §3.5 `RequestCursor`,
§3.8 `cpGet/cpPost`, §4.7 `OrderedSendQueue`, §7.1 `SignedS3Client`,
§7.2 `curl_common`, §7.4 `listUnderPrefix`, §5.4 directory axis table,
§8 JS shim dedup (time.toNs, id helper, authkit).
