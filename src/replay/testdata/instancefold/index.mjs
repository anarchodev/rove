// Scope across a resume: an instance must stay scope-resolvable in the
// chain's LATER activations (the exists marker folds forward with the
// effect log like any other store-tagged state). The instance is SEEDED by
// the scenario — creating one is a dispatched root activation now
// against `__root__`, not an in-handler verb.
export default function ({ after, next }) {
  after.fetch("https://api.example.test/seed", { on: "onSeed" });
  return next();
}

export function onSeed({ platform }) {
  platform.scope("neo").kv.set("hello", "1");
  return { ok: true };
}
