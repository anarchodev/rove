// A detached webhook/email delivery result handler (the `on` module). Runs as
// its own send_callback activation after the send commits — tested standalone
// via scenario().sendCallback(), NOT folded from a webhook.send emitter.
export default function () {
  kv.set("delivery/" + request.ctx.order, JSON.stringify({
    ok: request.ok,
    status: request.status,
    attempts: request.activation.attempts,
  }));
  return { recorded: true };
}
