// A detached webhook/email delivery result handler (the `on` module). Runs as
// its own send_callback activation after the send commits — tested standalone
// via scenario().sendCallback(), NOT folded from a webhook.send emitter.
export default function ({ kv }) {
  kv.set("delivery/" + request.ctx.order, JSON.stringify({
    ok: request.status >= 200 && request.status < 300,
    status: request.status,
    attempts: request.activation.attempts,
  }));
  return { recorded: true };
}
