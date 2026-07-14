// Holds on a connection timer; the wake reads the payload-less resume
// surface — accessors undefined (prod: no `bytes` on wake kinds), the
// activation bag kind, and the identity pinned on resumes too.
export default function () {
  after.ms(100);
  return next();
}

export function onWake() {
  return JSON.stringify({
    textUndef: request.text === undefined,
    bytesUndef: request.bytes === undefined,
    jsonUndef: request.json === undefined,
    kind: request.activation.kind,
    sessionNull: request.session === null,
    corr: request.correlation_id,
    tenant: request.tenant,
  });
}
