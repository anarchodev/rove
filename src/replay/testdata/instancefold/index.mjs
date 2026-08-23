// Create-then-scope across a resume: `platform.instances.create` in one
// activation must leave the instance scope-resolvable in the chain's LATER
// activations (prod: the create is durable state; sim: the exists marker is
// a store-tagged write that folds forward like any other).
export default function ({ after, next, platform }) {
  platform.instances.create("neo");
  after.fetch("https://api.example.test/seed", { on: "onSeed" });
  return next();
}

export function onSeed({ platform }) {
  platform.scope("neo").kv.set("hello", "1");
  return { ok: true };
}
