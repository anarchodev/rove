export default function () {
  // GET /?set=<key>&val=<value> writes via a handler so the commit-gated
  // kv_wake_broadcast fires (admin /_system/v2-kv does not wake watchers).
  const q = request.query || "";
  const params = new URLSearchParams(q);
  const key = params.get("set");
  if (key) { kv.set(key, params.get("val") || ""); return "set:" + key; }
  return "ready";
}

export function onMessage() {
  const { data } = request.activation;
  if (data.startsWith("watch:")) {            // arm an on.kv wake
    const prefix = data.slice(6);
    after.kv(prefix, { on: "onWake" });
    stream.write("watching:" + prefix);
    return next({ prefix });
  }
  if (data === "timer") {                      // arm an on.timer wake
    after.ms(500, { on: "onTimer" });
    stream.write("armed");
    return next();
  }
  stream.write("echo:" + data);
  return next();
}

export function onWake() {                      // kv under the prefix changed
  // Edge "go look" wake: request.activation.wakes[] names WHICH armed
  // prefix fired (issue #8 — never the matched keys); re-read
  // authoritative kv under it for the data.
  const fired = (request.activation.wakes || [])
    .filter((w) => w.kind === "kv")
    .map((w) => w.prefix)
    .join(",");
  const rows = kv.prefix(fired || "feed/");
  const last = rows.length ? rows[rows.length - 1].value : "<none>";
  stream.write("woke:" + last + "|fired:" + fired);
  return next();
}

export function onTimer() {                     // the timer elapsed
  stream.write("tick");
  return next();
}
