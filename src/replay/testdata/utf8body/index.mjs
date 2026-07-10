// Regression: a request body carrying multibyte UTF-8 must round-trip through
// request.json / request.text / request.bytes. The sim reconstructs the wire
// bytes as UTF-8 (not latin1), so JSON.parse sees the real characters instead of
// tripping over a truncated code point ("Bad control character").
export default function () {
  const j = request.json; // throws "Bad control character" under the old latin1 path
  return {
    name: j.name,          // 2-byte (á) + 3-byte (✓)
    emoji: j.emoji,        // 4-byte, surrogate pair (🚀)
    nested: j.nested.tag,  // em-dash + diaeresis
    byteLen: request.bytes.length,
    charLen: request.text.length,
    textParses: (() => { try { JSON.parse(request.text); return true; } catch (_) { return false; } })(),
  };
}
