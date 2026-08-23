// A cross-module fetch continuation — the `on_chunk` module of an UNBOUND
// http.fetch/http.subscribe (a SEPARATE chain), drivable standalone via
// scenario.fetchResult. An unbound continuation gets NO top-level flatten: the
// result rides request.activation.* — the terminal status on
// request.activation.status and the chunk payload on request.activation.bytes
// (a Uint8Array; decode for text). Records it under the threaded ctx key —
// proving the RIGHT module ran (only this file writes result/*).
export default function ({ kv }) {
  const ctx = request.ctx || {};
  const a = request.activation;
  const body = new TextDecoder().decode(a.bytes);
  kv.set("result/" + ctx.key, JSON.stringify({
    ok: a.status >= 200 && a.status < 300,
    status: a.status,
    body: body,
  }));
  // Prove the surface is UNBOUND: the flatten a bound resume would carry is
  // absent (no top-level request.status), the payload is on the activation bag.
  kv.set("surface/" + ctx.key, JSON.stringify({
    topStatus: request.status === undefined,
    activationKind: a.kind,
    bytesLen: a.bytes.length,
  }));
  return { done: true, key: ctx.key };
}
