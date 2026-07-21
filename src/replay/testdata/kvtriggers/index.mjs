// A handler whose users/ writes pass through the registered trigger.
export default function () {
  const p = request.path;
  if (p === "/good") { kv.set("users/1", JSON.stringify({ name: "ada" })); return { stored: kv.get("users/1") }; }
  if (p === "/bad") {
    try { kv.set("users/2", JSON.stringify({ age: 30 })); return { rejected: false }; }
    catch (e) { return { rejected: true, code: e.code, message: e.message }; }
  }
  if (p === "/del") {
    try { kv.delete("users/admin"); return { rejected: false }; }
    catch (e) { return { rejected: true, code: e.code }; }
  }
  return { ok: true };
}
