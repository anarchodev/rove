// A racing fan-in where each leg reads the PREVIOUS leg's next({ctx}). Two
// no-ctx after.fetches share one held chain; whichever lands first advances the
// chain ctx (`step` 0 → 1), and the second leg — armed WITHOUT its own ctx —
// must observe that bump, because the worker replaces the chain ctx on every
// re-hold and a no-ctx fetch resume reads the CURRENT chain ctx.
//
// Order-independent by construction: both orders terminate at step 2 with
// step/0 + step/1 recorded. Without the evolving-ctx thread the second leg
// re-reads step 0, re-holds, and the chain never terminates — the teeth.
export default function () {
  after.fetch("https://a.example.com/", { on: "onLeg" }); // no own ctx
  after.fetch("https://b.example.com/", { on: "onLeg" }); // no own ctx
  return next({ step: 0 });
}

export function onLeg() {
  const step = request.ctx.step;
  kv.set("step/" + step, "1"); // record which step THIS leg observed
  const nextStep = step + 1;
  if (nextStep >= 2) return { steps: nextStep }; // both legs in → terminate
  return next({ step: nextStep }); // advance the chain ctx for the other leg
}
