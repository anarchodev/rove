export default function () { return "ready"; }

export function onMessage() {
  const { opcode, data } = request.activation;
  if (opcode === 2) {              // binary → echo bytes back verbatim
    stream.write(data);
    return next();
  }
  if (data.startsWith("persist:")) {   // durable frame: reply commit-gated
    const v = data.slice(8);
    kv.set("ws/last", v);
    stream.write("persisted:" + v);
    return next();
  }
  if (data.startsWith("read:")) {      // kv read-back inside onMessage
    const v = kv.get("ws/last");
    stream.write("value:" + (v ?? "<none>"));
    return next();
  }
  if (data.startsWith("tag:")) {       // stamp who the next disconnect is
    const t = data.slice(4);
    kv.set("ws/tag", t);
    stream.write("tagged:" + t);
    return next();
  }
  if (data === "bye") {                // terminal return → server Close
    stream.write("closing");
    return "";
  }
  stream.write("echo:" + data);
  return next();
}

export function onDisconnect() {
  const tag = kv.get("ws/tag") ?? "none";
  kv.set("ws/disc_" + tag, "1");
}
