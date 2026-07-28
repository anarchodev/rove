// The compute surface runs offline, and native crypto is byte-faithful (NIST
// vectors), so auth/platform-heavy handlers (e.g. __admin__) can be tested.
import { scenario, expect } from "rewind:test";

const b = scenario({}).inbound({ method: "GET", path: "/" }).body;
expect(b.sha).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
expect(b.hmac).toBe("f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
expect(b.back).toEqual([1, 2, 3, 250]);
expect(b.uuid_len).toBe(36);
// jwt/sessions/oidc/oauth/users are no longer ambient globals — they're
// @rewind/* packages a handler must import. This asserts they're absent from
// the base (a removal guard); base64url stays an ambient primitive.
expect(b.surface).toEqual({
  jwt: "undefined", sessions: "undefined", oidc: "undefined",
  oauth: "undefined", base64url: "object", users: "undefined",
});
