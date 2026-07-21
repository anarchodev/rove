// Wake-fold parity against the per-arm-`{on}` worker (post-#142). A held
// connection can arm several `after.*` wakes; this fixture pins the three
// places the offline fold must match the runtime:
//
//   • multiple `after.ms` collapse to ONE armed slot — the worker overwrites
//     it, so the LAST-registered interval/`{on}` is the one that fires
//     (worker_dispatch.zig armCont: "last timer wins for the single timer
//     slot"). `/twotimers` arms two; only `onLate` may run.
//   • each armed wake resumes into its OWN `{on}` export (kv arm → `onMsg`,
//     timer arm → `onTimeout`), not one chain-level last-`{on}`-wins slot —
//     the live-cluster mirror is per_arm_wake_export_smoke_v2.py.
//   • an `after.kv` arm fires only for a change UNDER its prefix.
//
// Buffered (cont-family) holds — `next(ctx)` without `stream.start()`.
function hold(ctx) { return next(ctx); }

export default function () {
  if (request.path === "/twotimers") {
    after.ms(1000, { on: "onEarly" });
    after.ms(3000, { on: "onLate" });
    return hold({ armed: "twotimers" });
  }
  if (request.path === "/perarm") {
    after.ms(1200, { on: "onTimeout" });
    after.kv("msg/r1/", { on: "onMsg" });
    return hold({ room: "r1" });
  }
  return { ok: true };
}

// Only `onLate` may ever run for /twotimers — `onEarly`'s arm was overwritten.
export function onEarly() { kv.set("fired", "early"); return { fired: "early" }; }
export function onLate() { kv.set("fired", "late"); return { fired: "late" }; }

// Distinct arms, distinct exports.
export function onTimeout() { kv.set("route", "onTimeout"); return { via: "onTimeout" }; }
export function onMsg() {
  const w = request.activation.wakes[0];
  kv.set("route", JSON.stringify({ via: "onMsg", prefix: w.prefix }));
  return { via: "onMsg" };
}
