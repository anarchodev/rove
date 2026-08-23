// Exercises every emit-side vetting rule the worker applies to `response`
// and the return value (response_building.zig + worker_dispatch): header
// sanitize + caps, Set-Cookie Domain= strip, status coercion + clamp,
// auto/suppressed content-type, binary bodies, stream-then-terminal prepend.
export default function ({ stream }) {
  const p = request.path;
  if (p === "/head") {
    response.status = "207.9"; // ToInt32 coercion → 207
    response.headers = {
      "X-Custom": "Yes", // survives, lowercased
      "Set-Cookie": "evil=1", // platform-managed → dropped
      "content-length": "999", // platform-computed → dropped
      connection: "close", // hop-by-hop → dropped
      "x-rewind-tenant": "spoof", // platform-reserved → dropped
      "x-bad-value": "a\r\nb", // CR/LF value → dropped
      "x-num": 42, // non-string value → dropped
      ":status": "200", // pseudo-header → dropped
    };
    response.cookies = [
      "sid=abc; Domain=evil.com; Path=/; HttpOnly", // Domain= stripped
      42, // non-string → skipped
      "theme=dark",
    ];
    return "ok";
  }
  if (p === "/clamp-low") { response.status = 42; return ""; }
  if (p === "/clamp-high") { response.status = 9000; return ""; }
  if (p === "/cap") {
    const h = {};
    for (let i = 0; i < 40; i++) h["h" + i] = "v";
    response.headers = h;
    return "";
  }
  if (p === "/json") return { a: 1 };
  if (p === "/json-own-ct") {
    response.headers = { "Content-Type": "text/x-custom" };
    return { a: 1 };
  }
  if (p === "/bytes") return new Uint8Array([104, 0, 255]);
  if (p === "/stream-then-body") {
    stream.write("chunk1|");
    stream.write("chunk2|");
    return "tail";
  }
  return "?";
}
