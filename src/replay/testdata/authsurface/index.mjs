// Exercises the COMPUTE handler surface the sim base now installs (sim_globals):
// native crypto + the pure globals/*.js composed over it. Before the base
// prelude these ReferenceError'd offline; now they run for real.
export default function () {
  response.status = 200;
  return {
    sha: crypto.sha256("abc"),                       // native SHA-256 (0.3.4)
    hmac: crypto.hmacSha256("key", "The quick brown fox jumps over the lazy dog"),
    b64: base64url.encode(new Uint8Array([1, 2, 3, 250])),
    back: Array.from(base64url.decode(base64url.encode(new Uint8Array([1, 2, 3, 250])))),
    uuid_len: crypto.randomUUID().length,
    surface: {
      jwt: typeof jwt, sessions: typeof sessions, oidc: typeof oidc,
      oauth: typeof oauth, base64url: typeof base64url, users: typeof users,
    },
  };
}
