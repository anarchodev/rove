// The operator-root gate. An admin endpoint that proceeds only when the
// request carried a valid operator root token — the verdict arrives as
// `request.rewind.isRoot`, computed by the engine. The handler never sees a
// bearer: `authorization` is stripped on a platform-bound handler, because a
// header the handler reads is a header the tape records
// (docs/architecture/privileged-surface.md).
export default function () {
  if (!request.rewind.isRoot) {
    response.status = 403;
    return { ok: false };
  }
  return { ok: true, admin: true };
}
