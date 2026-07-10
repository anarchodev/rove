# `wake` primitive — spec (package-manager chore 1 / P-Wake)

Status: **proposal, 2026-07-09.** No code yet. The engine-side prerequisite
that lets the durable-timer *ergonomics* (`@rewind/schedule`, and the
`cron` / `retry` wrappers on top) become tenant-pinnable packages — while
the durable-timer *queue itself* stays a frozen platform primitive. See
`docs/plans/package-manager-plan.md` §1.C.9 + §2 (tiering) and memory
`project_globals_to_packages`.

**Design (locked in conversation 2026-07-09): frozen queue.** The
durable-timer queue + fan-out is a **frozen primitive** — public `wake`
verbs over the existing `_system`-family natives + the baked
`__system/scheduler_tick`. This is the webhook shape: `webhook` is a
frozen ambient shim over `_system.http`; `wake` is a frozen ambient shim
over `__rove_set_wake` / `__rove_fire_wake`. Packages compose over the
public `wake` global, never the natives. The **queue is not
tenant-pinnable** — at-least-once timer firing is security-critical
durability infra, exactly like webhook's at-least-once delivery
(primitives-vs-wrappers, `package-manager-plan.md` §1.B). Only the
ergonomics (`{in}`/`{at}` coercion, durations, `cron`) is the pinnable
package.

**Non-goal:** changing durability semantics (at-least-once firing,
one-watermark-per-tenant, hibernating active-set) — preserved verbatim.

---

## 1. What exists today

Engine/JS split across three files:

- **Engine — one volatile watermark + a 1 Hz sweep.**
  `TenantSlot.next_wake_ns` (atomic, volatile, never replicated; `0` = no
  wake). `sweepDurableWakes` (`durable_wake.zig:47`) fires
  `__system/scheduler_tick` for due tenants in its partition.
  `noteCommittedSchedWrites` (`:144`) — commit-gated watermark bootstrap:
  on commit of a `_sched/by_time/{whenNs}/{id}` put, `slot.lowerWake`.
  `sweepDurableWakesOnPromotion` (`:88`) — on leadership gain, probe
  `_sched/by_time/` and re-fire the tick to rebuild watermarks.
- **Two privileged natives** (`bindings/scheduler.zig`, gated
  `is_system_module`): `__rove_set_wake(whenNs)` — set-exact/clear the
  watermark; `__rove_fire_wake(target,id,key,scheduledAtNs,msg,cleanup)`
  — spawn one `durable_wake` activation, deleting `cleanup` keys in the
  spawned activation's writeset (exactly-once on the normal path).
- **JS.** `globals/schedule.js` (public verb; writes the queue kv, owns
  ordering/idempotency/caps). `builtin_modules/scheduler_tick.mjs` (baked
  privileged fan-out: scan `_sched/by_time/` for due entries →
  `__rove_fire_wake` each → recompute min → `__rove_set_wake`).

## 2. The one coupling to sever

`_sched/by_time/` — the queue layout — appears in three places:

| Place | Coupling | Verdict |
|---|---|---|
| `schedule.js` (writes) | its own kv layout | moves *into the frozen `wake` shim* (§4) |
| `scheduler_tick.mjs` (scan) | reads the layout | **stays baked** — now the `wake` primitive's private layout |
| **`durable_wake.zig`** (`SCHED_BY_TIME_PREFIX`) | the **engine (Zig)** hardcodes the layout — commit-sniff + promotion probe | **must go** — the engine stops knowing any kv layout |

The fix moves layout knowledge *out of Zig* (`durable_wake.zig`) but
keeps it in **frozen JS** (the `wake` shim + the baked tick) — the
§3.3-aligned shape (Zig owns watermark + natives; JS owns the queue). The
tick and the natives stay **exactly as privileged as today** — no
de-privileging, far less churn than making the tick a package module.

## 3. The public `wake` surface

A new ambient **frozen** primitive `wake` (capability-surface tier, never
tenant-pinnable). Three clean verbs, **all callable from any handler,
none privileged/context-gated** — the privileged ops stay behind the
`__rove_*` natives the shim closes over:

```
wake.at(whenNs, target, ctx?, opts?)  → id      // arm one durable timer
wake.cancel(id)                        → boolean  // remove it
wake.get(id)                           → {id, whenNs, target, key} | null
```

- `wake.at(whenNs, target, ctx?, {key?})` — arm `target` to run once at
  absolute `whenNs` (bigint ns) as a fresh connectionless activation with
  `ctx` as `request.ctx`. `opts.key` = idempotency key (same key ⇒ same
  id ⇒ last-write-wins re-arm). Returns the stable id. The shim (a) writes
  the frozen queue rows, (b) reifies a **commit-gated** watermark-lower
  (§4) so the tick that fires sees the committed entry. ns-only and exact
  — human coercion (`{in}`/`{at}`, durations) is the `@rewind/schedule`
  package's job (§5).
- `wake.cancel(id)` / `wake.get(id)` — ordinary reads/writes over the
  frozen queue kv.

At-least-once firing (the target owns dedup); the primitive does not retry
a failed target — retry composes on top (that's `@rewind/retry`).

## 4. Engine changes (tiny — the queue is frozen, so keep the sniff)

Because the wake **queue is a frozen primitive** (not a tenant package),
the engine is allowed to know its kv layout — engine and primitive are
both platform-frozen and version together. So the decoupling that an
earlier draft proposed (drop `SCHED_BY_TIME_PREFIX`, add a commit-gated
`wake.at` arm-Cmd + an `__rove_arm_wake` native) is **not needed and is
dropped.** `wake.at` needs **no privileged native at all**.

1. **`durable_wake.zig` — unchanged mechanism, keep the commit-sniff.**
   `noteCommittedSchedWrites` still lowers the watermark on a committed
   frozen-queue put; `sweepDurableWakes`/`OnPromotion` still fire
   `__system/scheduler_tick`. (Optional cosmetic: rename the layout string
   `_sched/by_time/` → `_wake/by_time/`.)
2. **New frozen shim `globals/wake.js`** (capability-surface eval group):
   `wake.at/cancel/get` — **pure kv composition.** `wake.at` writes the
   frozen queue rows via the ambient `kv` shim; the engine's existing
   sniff lowers the watermark. No native, no Cmd. This is essentially
   `schedule.js`'s durable core extracted verbatim.
3. **`scheduler_tick.mjs`** — unchanged; stays baked + privileged; calls
   the gated `__rove.wake.set` / `__rove.wake.fire` (the privileged
   tick-only ops, see `privileged-surface-and-ratelimit-spec.md` §2).
4. **`bindings/scheduler.zig`** — `set_wake`/`fire_wake` unchanged
   (privileged, `is_system_module`), just re-homed under the `__rove.wake.*`
   holder. No new native.

## 5. `@rewind/schedule` — the pinnable ergonomics wrapper (P-Lift)

Slimmed. `@rewind/schedule` becomes pure composition over public `wake`:
- `schedule({ in | at }, target, ctx?, {key?})` — coerce `{in}` (number
  ms / duration string via `cron.parseDuration`) or `{at}` (Date /
  ISO-8601 / ms / bigint ns) → `whenNs`, then `wake.at(whenNs, target,
  ctx, {key})`. Round-up-to-tick + the msg-size/outstanding caps live
  here (or in the shim — §8).
- `schedule.cancel/get` → `wake.cancel/get` passthrough.
- `cron` / `retry` compose over `schedule` (or directly over `wake`) —
  unchanged, packageable for free.

The durable machinery (queue layout, fan-out, watermark, at-least-once)
is *entirely* in the frozen `wake` primitive; the package is coercion +
policy. A tenant pins the ergonomics, never the delivery guarantee.

## 6. Invariants preserved (must not regress)

At-least-once firing / exactly-once on the normal path (unchanged
`fire_wake` cleanup contract); the fire↔commit self-heal (the tick's
immediate `set_wake` re-arm; a crashed tick leaves the watermark due);
one volatile watermark per tenant + hibernating active-set (unchanged);
caps (kept in the shim/package). All of §1's mechanics stay **fully
intact** — the engine keeps its commit-sniff of the (frozen) queue layout;
nothing about the watermark/self-heal/promotion path changes. The only
real move is extracting `schedule.js`'s durable core into the frozen
`wake.js` shim.

## 7. Determinism / replay / security

- **Replay:** the tick activation is a recorded `durable_wake` Msg; each
  fire spawns a further recorded Msg. `wake.at` is a reified taped effect.
  The watermark is volatile (reconstructed, not replayed).
- **Security:** `wake` is a **frozen primitive** (never tenant-pinnable;
  `overrides` can't retarget it). The public `wake.at/cancel/get` shim is
  **native-free** — pure kv. The privileged tick ops (`__rove.wake.set` /
  `__rove.wake.fire`) are `is_system_module`-gated and never in the public
  surface (`privileged-surface-and-ratelimit-spec.md` §1–2). Customer
  `wake.at` reaching only `kv` means there's no privileged surface to
  leak.

## 8. Open questions

1. **Caps home** — outstanding/msg-size caps in the frozen `wake` shim
   (enforced for every timer, incl. custom `wake.at` users) vs the
   `@rewind/schedule` package (only its callers). Lean: the **shim** —
   the caps protect the engine's queue, so they belong to the primitive.
2. **`@rewind/schedule` worth a separate package?** It's thin (coercion +
   passthrough). Could fold into `@rewind/cron`. Decide at P-Lift.

## 9. Test plan

- Inline Zig: the engine sniff still lowers the watermark on a committed
  frozen-queue put (unchanged); `__rove.wake.set`/`fire` remain
  `is_system_module`-gated after the re-home under the holder.
- Port the existing scheduler smokes onto the extracted `wake.js` + public
  `wake.at`: arm→fire; cancel; idempotent re-arm; crash-between-fire-and-
  commit re-fire; leadership-gain reconstruction; `MAX_FIRES_PER_TICK`
  backlog drain — all must stay green with **zero semantic diff** (the
  durable core is moved verbatim, not redesigned).
- `cron` + `webhook.send` retry (both compose over schedule/wake) still
  fire end-to-end.
