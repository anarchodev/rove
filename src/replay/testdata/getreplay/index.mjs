import browser from "@rewind/browser";
// A WS agent handler whose onMessage pulls the session's replay log via
// browser.getReplay (a bound fetch to rewind-logs.internal keyed on the
// engine-pinned per-chain identity: request.tenant + request.correlation_id).
// Mirrors rewind-apps:agent-sample's think() replay leg. Without a
// correlation_id, getReplay can't build the logs URL and returns false — so the
// success bounce into onReplay is only driveable when a test supplies both ids.
export function onMessage() {
  const issued = browser.getReplay({ on: "onReplay" });
  if (!issued) {
    stream.write("replay unavailable");
    return; // terminal — nothing to await
  }
  return next(); // hold for the bound replay fetch
}

export function onReplay() {
  kv.set("replay/log", JSON.stringify({ ok: request.status >= 200 && request.status < 300, body: request.text }));
  stream.write("replay ready");
  return;
}
