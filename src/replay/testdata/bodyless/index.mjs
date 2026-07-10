// Reads the request payload unconditionally — the shape that broke on an authored
// bodyless inbound (admin/index.mjs does `rawBody: request.text || ""`). In prod a
// bodyless request reads as empty (request.text === "", 0-length bytes), so this
// must NOT throw when no body was declared; it returns the payload length.
function payloadLen() {
  const text = request.text || "";
  return String(text.length) + ":" + request.bytes.length;
}

export default function () { return payloadLen(); }

// Headers-first entry is bodyless too (the body hasn't been accepted) — reading
// the payload here must read empty, not throw.
export function onHeaders() { return payloadLen(); }
