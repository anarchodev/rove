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
  // Edge "go look" wake: re-read authoritative kv (onWake doesn't get
  // request.ctx — it re-reads the watched prefix it knows it armed).
  const rows = kv.prefix("feed/");
  const last = rows.length ? rows[rows.length - 1].value : "<none>";
  // issue #8: the matched keys ride along on request.activation.wakes[]
  // even on the WS resume path (a hint on top of the "go look" re-read).
  const hint = (request.activation.wakes || [])
    .filter((w) => w.kind === "kv")
    .map((w) => w.op + ":" + w.key)
    .join(",");
  stream.write("woke:" + last + "|" + hint);
  return next();
}

export function onTimer() {                     // the timer elapsed
  stream.write("tick");
  return next();
}
