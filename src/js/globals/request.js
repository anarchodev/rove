// The uniform payload surface — `request.text` / `request.json` derived
// from `request.bytes` (decisions.md §4.11).
//
// `bytes` (a Uint8Array) is materialized per activation kind in Zig
// (`installRequest`): a lazy read-recording accessor on plain inbound,
// a data property on the chunk / bound-fetch / ws / send_callback kinds
// (their payload IS the activation's recorded Msg), and absent on
// payload-less activations (wakes, cron/schedule targets, disconnect).
//
// `text` and `json` live here, on a shared prototype every per-request
// object gets, so they are defined once at snapshot build (zero
// per-request cost) and work identically on every payload-carrying
// activation kind:
//   - text: WHATWG-lenient UTF-8 decode (invalid sequences → U+FFFD).
//   - json: JSON.parse(text) — throws on non-JSON, which is a real
//     handler error, not something to paper over.
// Both go through `this.bytes`, so whatever read-recording the bytes
// accessor does covers them; both self-replace with own data properties
// so repeat reads cost nothing. On a payload-less activation they read
// undefined (bytes is absent) and return undefined. (`request.body` is
// RETIRED — these accessors are the only payload surface; the replay
// driver alone still synthesizes a `body` so records from
// pre-retirement deployments replay their pinned code.)
(function () {
  "use strict";
  var proto = {};
  Object.defineProperty(proto, "text", {
    configurable: true,
    get: function () {
      var b = this.bytes;
      if (b === undefined) return undefined;
      var v = new TextDecoder().decode(b);
      Object.defineProperty(this, "text", { value: v, configurable: true });
      return v;
    },
  });
  Object.defineProperty(proto, "json", {
    configurable: true,
    get: function () {
      var t = this.text;
      if (t === undefined) return undefined;
      var v = JSON.parse(t);
      Object.defineProperty(this, "json", { value: v, configurable: true });
      return v;
    },
  });
  globalThis.__rove_request_proto = proto;
})();
