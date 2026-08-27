# fat-entity branch — task ledger

Working state for the `fat-entity` branch. The design record and the
arguments live in [`fat-entity-model.md`](fat-entity-model.md); this file
is only what remains to do, roughly in dependency order. If the direction
is adopted, in-flight items graduate to GitHub issues and durable residue
into `docs/architecture/` + `decisions.md` per the repo's normal process —
this file then dissolves.

## Shipped on this branch (orientation only)

FatRegistry (shadow now AoS with per-entity `{gen, written}` header) ·
total/lossless moves · `getFat` · `getRow`/RowView · declared collection
ids (coll-enum merged) · `collectionIdOf` · `EntitySet` + per-entity mask ·
`evictImmediate` · Io generic over registry model · echo server on fat
(probe-verified) · zero hooks and zero residency contracts in fat io ·
`all_conns` admission + sweep · empty-queue precondition on the sweep ·
fat-bench (parity at every altitude measured) · getAny/moveAny compat ·
conn_dead hand-off phase + reaper · **rove-h2 ported** (h2-echo-fat
probe-verified) · **declared world** (`rove.World` tables: parts per
layer, ids by table position, registry-owned storage, sets as row-less
registry-internal entries addressed by tag) · **`rove_world` root
pattern** (both fat examples; fat-without-world is a compile error;
explicit `.world` for tests' mini-worlds) · the extra_components
threading deleted with it.

## 1 — Universe composition — BUILT 2026-08-26 (threading), REBUILT as the declared world (same day)

"Top" is a role, not a layer: whoever terminates the stack in a given
program (echo example → io directly; h2-echo example → h2; the rewind
worker → h2 + its own collections — the case `extra_collections`
already exists for). The design must work when top is two layers above
io with components io has never heard of.

- [x] **`extra_components: Row` at every layer boundary, folded
      downward.** Each layer merges its own non-row components plus its
      caller's extras into what it passes the layer below; io (bottom)
      computes `universe = own_rows ∪ extras` and defines `Reg`; each
      layer re-exports `pub const Reg = Below.Reg`. Exactly parallel to
      `extra_collections` for the id namespace — one aggregate per
      boundary, threaded down.
      - Division of labor: the BOTTOM defines the type, MIDDLES fold
        and forward, the TOP contributes, constructs the registry
        value (`Reg.init`), and registers its own collections against
        it. Row options stay the materialization requests ("in your
        views"); extra_components is existence ("in the world").
- [x] **No ordering fragility, unlike the id enum.** Row unions are
      canonical (sorted, deduplicated), so the same component set gives
      the identical type regardless of merge order or which layer
      computes it — no prefix assertion needed; a mismatched union is a
      pointer-coercion error at the seam, a missing component is the
      coverage error at the offender's own registerCollection, both at
      compile time.
- [x] **Gap B, same mechanism:** "in the world, materialized nowhere" —
      a component in no row gets its shadow field via extra_components
      alone; the materialization knob's zero position.
- [x] Built FLAT. The declared-world interface (components +
      collections tables, table-position ids, registry-owned storage)
      remains the intended successor; the threading is its sanctioned
      fallback and is subsumed by it.
- [x] **BUILT (2026-08-26): the `rove_world` root pattern + declared
      world tables** (`src/rove/world.zig`) — the std_options idiom:
      each binary's root module declares `pub const rove_world =
      rove.World(.{ .parts = ... })` once; rove exposes
      `declared_world` via @import("root") with null fallback; layers
      consult it (explicit `.world` wins, for tests' mini-worlds).
      All five soundness rules hold as designed: types at root /
      values in main, `.fat` stays on instantiations with
      fat-without-world a compile error, parts are pure data at file
      scope (`rio.parts` / `rh2.parts`, sharing the layer's own row
      computation so root and instantiation cannot drift — a comptime
      identity check per collection proves it), library test builds
      see null, heterogeneous worlds out of scope. What the build
      added beyond the decision record: ids by table position valued
      as registry ids directly (`W.CollId`, h2's `Coll` IS it under a
      world — `extra_collections` dissolves into the composer's own
      parts, the io-names-first prefix contract binds only the
      archetype enum); registry-owned storage behind one heap Storage
      pointer so `Reg.init` keeps the value-returning idiom; sets as
      row-less entries in the same table, registry-internal and
      tag-addressed (`join/leave/inSet/setMembers`) — the axes-4c
      storage merge can now land with zero consumer blast radius; the
      `coll(.name)` accessor as the one address-taking spelling valid
      under every model. When axes (item 4) land, the contribution
      becomes per-axis and the re-grouping is mechanical.

## 2 — The h2 port (the real consumer test)

- [x] Genericize rove-h2 over the registry model — DONE (2026-08-26).
      extra_components threading built at both boundaries (item 1's
      fallback mechanism; the declared-world interface still supersedes
      it later); Reg re-exported; hooks not installed under fat. Two
      foreign-state problems surfaced and solved: (a) Conn.deinit's
      work (nghttp2/TLS/h1) moved to the `conn_dead` hand-off phase —
      io retires by move under `on_retire = .hand_off`, h2's
      pollPostlude reaps (free via getFat, then destroy), teardown
      reaps conn_dead AND still-closing; (b) the four buffer-owning
      stream components route every ending through `destroyEntity`
      (frees-then-destroys under fat; safe on any entity via
      null-defaults). Probe-verified: churn/multiplex/concurrency,
      byte-exact, archetype control identical.
- [ ] Convert the four stream components (Req/Resp Headers/Body) to
      release-by-transition or per-request arena — h2's analog of
      rove#885. Retires destroyEntity's fat branch and the consumer
      contract ("end terminal entities through destroyEntity").
- [ ] The h2-side call sites that want `getRow` (close/dispatch paths
      reading several components of a stream) — currently on compat
      getAny/moveAny, which FatRegistry now provides.
- [x] **Smoke suite — RUN 2026-08-26 after the declared-world arc:**
      167/168, and vs baseline the one "newly broken"
      (log_failover_walker_smoke_v2) passed standalone on an idle box —
      its two in-suite failures coincided with concurrent zig compiles,
      the saturated-box election-timeout class. So the suite is green
      for the arc: the archetype h2/io accessor sweep (~380 sites) is
      smoke-verified, not just unit-gated. The worker still runs
      archetype — a fat worker needs its own suite run when it opts in.

## 3 — Edge clauses

- [ ] `leaves = .{...}` on moves/evicts: the edge performs membership
      repair atomically. Prefer over asserts (edges do work).
- [ ] `asserts = .{...}`: framework-owned explicit check-and-abort that
      survives ReleaseFast. This is also where the lost `Fd.deinit`
      bypass-abort class returns — declared preconditions on edges
      instead of destructor-time detection.
- [ ] Constraint: evict edges can carry only destination-dependent
      clauses (source is runtime-resolved); source-dependent ones
      degrade to runtime asserts. Write this down in the clause design.
- [ ] The checkable-handoff successor to the row-subset rule; a debug
      `getRow` variant asserting requested members were written this
      generation (the header mask already answers it).

## 4 — Membership axes

Ship each step alone: (a) is pure annotation, (b) must be bit-identical
for the single-axis case, (c) delivers the first real second axis, (d)
comes last so only the constraints that survive 4a–4c get syntax.

**SPIKE DONE 2026-08-26, file DELETED 2026-08-27 with 4d's landing
(all conclusions graduated):** the throttle test-world validated the
mechanics end to end.
Per-axis `(id, offset)` records give dense co-residency with zero
copies; `axisOf(T)` comptime-resolves so the cross-axis getFat is ONE
membership lookup; leave parks / re-enter restores (path-independence's
sharp edge held); a state-attached `on_enter_leaves` clause fires on
every entry path because move and enter funnel through one point —
evidence for 4d's state-attached-as-default lean; destroy exits every
axis and per-axis offsets stay exact under swap-remove churn.

- [x] **4a. Partition — BUILT 2026-08-26, as the EMERGENT form.** No
      axis-owned row: a `CollDecl` tags `.axis` (default
      `rove.lifecycle`), a component INHERITS the axis of the
      collections that materialize it, and materialization on two axes
      is the compile error (named component, both sites) — so the
      partition falls out of the tables the world already has, the
      universe stays the row union, and the shadow struct is axis-blind
      and unchanged. `W.axes` lists distinct axes (lifecycle first),
      `W.axisOf(T)` resolves a component (null = shadow-only,
      axis-free), `W.axisOfColl(id)` a collection. Sets take no
      `.axis` — a set IS its own one-state axis until 4c merges the
      storage. Co-residency safe
      by construction — the disjointness condition becomes a property of
      the type system, no pairwise or runtime checks. Why a
      data-carrying axis at all: a system gets DENSE iteration over an
      orthogonal concern's state (a `throttled` collection whose refill
      system iterates only limited conns) — a set can't (no columns), a
      flag can't (scan everything), the single membership can't (slot
      taken by lifecycle). `close_requested`, the style guide's
      confessed flag-exception, exists because the slot was occupied.
- [ ] **4a-identity. Axes are declared VALUES with owners, not merged
      names.** String-matched axis names invite accidental capture: two
      layers independently inventing `.pending` for unrelated concerns
      get silently fused into one axis, imposing exclusivity between
      states that have nothing to do with each other — valid
      declarations, no error. So: a part EXPORTS the axes it owns
      (`pub const throttle_axis = ...`), layers above reference the
      decl (`.axis = rio.throttle_axis`) — unforgeable, typo-proof,
      private by default, shared only by explicit import; the world
      merges by identity. The total axis is rove's own (`rove.
      lifecycle`, the default when `.axis` is omitted) because
      liveness is the registry's concept. Layering is reference-DOWN
      only: upper layers contribute collections into axes lower layers
      export; io cannot see h2's. Cross-layer shared axes are not new
      capability — today's single membership byte IS an unnamed
      lifecycle axis spanning io and h2 (conn adoption is a move
      because of cross-layer exclusivity on it); naming makes the
      sharing addressable. Interface rule per co-residency: overlap
      freely WITHIN an axis (state alternation — the whole h2 chain),
      never across axes (contested storage); the checker's error names
      the component and both sites. Not axis-representable (conflict
      graphs that are not disjoint unions of cliques, e.g. two
      overlapping tilings / K2,2): rejected at declaration — remodel
      by flattening cliques, splitting meanings into distinct
      components with declared sync, or (someday, with cause) a mode
      byte selecting the active partition.
- [x] **4b. Mechanics — BUILT 2026-08-26.** `FatRegistryAxes(Universe,
      AxesSpec)` with `FatRegistry` = the single-axis instantiation.
      The total axis KEEPS `collection_ids`/`offsets` literally —
      single-axis stays shape-identical by construction, `axisIds(ax)`
      comptime-folds to the classic fields when n_axes == 1, and
      fat-bench confirms parity (move 5.7, churn 11.5, getFat 2.3–2.5
      ns/op — the pre-axes figures). Partial axes are parallel
      `(id, offset)` arrays; id namespace stays global 0..255 so
      coll_ptrs / column_fns / recipes are unchanged; collections carry
      `axis_index` from `registerCollectionOnAxis` (which re-checks the
      partition), and `id_axis` records it per id. getFat computes the
      axis at comptime; evict takes the axis from dst; destroy exits
      every partial axis via the evict recipes before the generation
      bump (their parks are dead bytes the bump invalidates); create
      refuses partial-axis destinations (birth is a total-axis event).
      DELTAS from the pinned sketch: the src/dst same-axis check is a
      RUNTIME error at the verb (registration is runtime, so the core
      cannot comptime it; the world's table could later), and
      PENDING_MOVE stays ONE flag freezing the whole entity across
      axes — conservative, one byte. The world derives the AxesSpec
      from the emergent partition and registers entries onto
      `axisIndex(d.axis)`. Partial-axis collections are UNREACHABLE
      until 4c's enter/leave land — this step is the plumbing under
      the unchanged single-axis behavior (127 tests green).
- [x] **4c. Total vs partial — BUILT 2026-08-26.** As pinned, with the
      set/collection storage merge landing exactly as pre-paid: the
      world's tag API (join/leave/inSet/setMembers/setCount) is
      UNCHANGED — its test passed unmodified across the swap — while
      underneath EntitySet, the membership mask, registerSet, and
      MAX_SETS are deleted; a set is Collection(empty row) on a
      one-state axis of its own (world axes = declared axes + one per
      set entry), its dense list is the collection's entity slice, its
      sparse table is the axis offsets, and destroy's exit-every-axis
      walk replaces the mask. Core gains enter (Gained path, no
      source; refuses the total axis), leave (Dropped path, no
      destination — PARKS through the type-erased evict recipe, so the
      caller never names the collection; idempotent-false; refuses the
      total axis), and onAxis; the world adds enter/leaveAxis/onAxis
      over declared axes. Verb availability by shape holds: create is
      total-only, leave is partial-only, move stays within-axis. The
      throttle case runs for real at the world level: dense iteration
      over the orthogonal columns, lifecycle moves leaving the
      membership alone, leave-parks/re-enter-restores. Original
      sketch, for the record: Exactly ONE total axis (lifecycle):
      position always exists, 0 = free pool, birth requires it, no
      leave, evict's reserve-first no-limbo discipline applies. All
      other axes partial: 0 = "not on this axis" (legal — liveness is
      the total axis's and the generations' job). Partial axes gain
      `enter` (Gained-path with no source) and `leave` (Dropped-path
      with no destination — PARKS, nothing destroyed). Freshness sharp
      edge: re-enter restores parked values (path-independence); the
      system deciding `leave` owns resetting first if policy wants a
      fresh start — same contract as `fd = -1` at close. A set is a
      partial axis with zero components — and at this step the
      implementations MERGE (no half-refactor): the consumer surface
      is ALREADY tag-shaped (the declared world made sets row-less
      registry-internal entries), so the merge is storage-only with
      zero consumer blast radius; EntitySet is deleted;
      sets become Collection(empty row) on one-state axes (the shared
      recipes' component loops vanish at comptime for an empty row);
      the set's sparse table moves into the per-axis offsets where it
      always belonged; the membership mask is deleted too (its drain
      win is moot when destroy walks K axis bytes anyway) and may
      return as a private compression only if dozens of tag axes ever
      exist. What stays distinct is verb availability derived from
      axis shape: total = create/move/evict, no leave; multi-state
      partial = enter/move/leave; one-state partial = enter/leave.
- [x] **4d. Cross-axis constraints — RESOLVED 2026-08-27 as VERBS,
      not declarations.** Quiescing is something a system SAYS at the
      transition: `moveOnly` / `moveAnyOnly` (deferred, like their
      plain forms) and `evictOnly` (immediate, erased source) move to
      dst and leave every other non-identity partial axis — the call
      site names no axes, so a state axis added later is dropped at
      existing quiesce sites unchanged, and the destroy backstop
      (exit every axis) bounds a forgotten quiesce to stale
      co-membership until retirement. The seams adopted it: io's
      teardown sweep evicts with `evictOnly`, h2's `closeConn` funnel
      moves with `moveAnyOnly` (the archetype Registry aliases the
      Only verbs to the plain ones — single membership is trivially
      "only"). IDENTITY axes are the exemption that makes the verb
      correct: a set entry may declare `.identity = true` (all_conns
      does — admission and the sweep count closing conns, and the
      sweep iterates the member list it must not mutate); identity
      says what the entity IS and ends only at leave/destroy. io's
      birth ritual consolidated into `birthConn` (create + fd + peer +
      identity join in one place; the connect promotion upholds the
      same invariant).
      **REJECTED: state-attached constraint declarations** on the
      CollDecl (`on_enter = .{ .leaves = ..., .excludes = ... }`,
      or a world-level entanglement table). Reasons: behavior-in-data
      where this codebase's proven pattern is the funnel verb
      (closeConn / destroyEntity / shutdownAllConns); reading a move
      should show everything it does; the backstop already makes the
      guarded failure soft, so structural unbypassability bought
      little; and the clause vocabulary was growing toward a DSL.
      Do not re-propose without new information. What survives of
      that design: §3's edge ASSERTS (checks, not behavior — the Fd
      bypass-abort class firing at the transition where the story is
      tellable) remain open and compatible with the verb shape; the
      rule of thumb is "a membership whose exit requires releasing a
      resource declares an assert, never relies on a silent leave."
      Guard added with the verbs: deferred move/moveAny refuse
      partial-axis SOURCES (`DeferredPartialAxis`) — the queue records
      offsets at enqueue, and flush-time axis exits (destroy's,
      moveOnly's) may shift partial collections; partial memberships
      mutate immediately (enter/leave/moveImmediate), which every
      real site already did.

## 5 — Deferred + batch evict

- [ ] Count-N evict recipe (the generalization `moveRecipe` already has).
- [ ] Deferred evict: coherent because PENDING_MOVE freezes the entity;
      needs the source id/recipe threaded through the op.
- [ ] Batch evict: sort the worklist (counting pass on the id byte,
      offsets within), runs form at enqueue via RLE; all-members sets
      yield complete contiguous runs (K entities, M collections, M ops).
- [ ] The shadow bypass: components the source also materializes
      (null-check in the accessor table) copy column-to-column, one
      memcpy per component per run; only the row difference parks
      (scatter — unavoidable, the price of address stability). Needs a
      destination component-mask handed to the erased half.
- [ ] Rewire the fat sweep onto sorted batch evict once built.
- [ ] First deferred-evict consumer when it appears: the mid-tick idle
      reaper pattern (cannot prove immediate-safety, unlike teardown).

## 6 — Smaller items, any order

- [ ] Cold-working-set benchmark for the AoS shadow (the clustering win
      is claimed from mechanics, unmeasured — hot-cache bench shows
      parity only).
- [ ] Bench scenario B (h2-shaped composite tick) if the h2 port wants a
      number before committing.
- [ ] `EntitySet` dense-half capacity option for genuinely bounded sets
      (deliberately deferred: reintroduces the `Full` arm and a
      backpressure story; "join cannot fail" is worth real money).
- [ ] Consider root-level exports for `RowView`/`EntitySet` (currently
      via `rove.fat_mod`).
- [ ] Universe > 64 components: widen the header mask (compile error
      guards it today).

## 7 — Main-worthy independent of this branch (cherry-pick candidates)

- [ ] `moveAny` comptime quota fix (`584c4e19`) — any wide-row
      many-candidate call site on main hits it.
- [ ] Echo example modernization (`9de61f85`) — the example on main
      still destroys conns directly (aborts on first disconnect under
      the Fd guard) and leaks write buffers.

## Process, before merging anywhere

- [ ] Smoke suite green with baseline (see item 2).
- [ ] Decide the relationship to the parked `coll-enum` branch (this
      branch contains it; landing either implies sequencing).
- [ ] The actual adoption decision — "does rove become this" — is
      deliberately not argued in the model doc and needs its own
      conversation, with PLAN/decisions.md updates if yes.
