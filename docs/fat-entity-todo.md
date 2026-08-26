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
fat-bench (parity at every altitude measured).

## 1 — Universe composition (blocks the h2 port)

- [ ] A way for a stacking layer to widen the universe: either an
      `extra_components: Row` option threading up from the top, or the
      app computes the union and hands the `Reg` type into each layer.
      Mirrors what coll-enum already does for the id namespace with
      `opts.extra_collections`.
- [ ] "In the world, materialized nowhere": a component in no row
      currently has no shadow field. Same mechanism as above — the
      universe must be declarable beyond the union of rows.

## 2 — The h2 port (the real consumer test)

- [ ] Genericize rove-h2 over the registry model the way io went.
      Expected mostly mechanical after item 1; the `conn_closing`
      two-type `getAny` seam dissolves under fat (rows never diverge).
- [ ] The h2-side call sites that want `getRow` (close/dispatch paths
      reading several components of a stream).
- [ ] **Smoke suite** (`scripts/smoke/run_all.py --baseline`) — owed
      since the coll-enum merge regardless, mandatory before any of this
      approaches main. `zig build test` cannot see socket lifecycle.

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

- [ ] Component→axis partition declared at comptime; a collection
      materializes only its axis's components; cross-axis co-residency
      safe by construction.
- [ ] `collection_ids` becomes one byte per axis; per-membership offsets
      move into per-collection sparse indexes (the EntitySet layout —
      sets are the rehearsal).
- [ ] Total vs partial axes: lifecycle total (no-limbo, evict's
      reserve-first discipline), tag/seam/index axes partial (`leave` is
      legal). Sets become one-state partial axes of the general thing.
- [ ] Cross-axis constraints ("entanglement") expressed as edge clauses
      — the actual design work hiding inside the axis idea.

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
