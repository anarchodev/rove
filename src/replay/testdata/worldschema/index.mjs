// scenario() can author a binary inbound body (bodyBinary → request.bytes,
// byte-exact) and an explicit export override (#54).
export default function () {
  const b = request.bytes;
  let sum = 0;
  for (let i = 0; i < b.length; i++) sum = (sum + b[i]) & 0xffff;
  return { len: b.length, sum, first: b[0], last: b[b.length - 1] };
}

export function onCustom() {
  return { via: "onCustom", path: request.path };
}
