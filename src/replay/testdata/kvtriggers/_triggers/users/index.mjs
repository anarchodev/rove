// A kv trigger on the "users/" prefix (trigger_dispatch.zig contract): beforePut
// validates + NORMALIZES (a string return mutates the stored value); an invalid
// write THROWS → the platform rethrows as Error{code:"trigger_rejected"}.
export function beforePut(event) {
  const v = JSON.parse(event.value);
  if (!v.name) throw new Error("name required");
  v.normalized = true;
  return JSON.stringify(v);
}
export function beforeDelete(event) {
  if (event.key === "users/admin") throw new Error("cannot delete admin");
}
