// A real RSA-2048 RS256 token + its IdP JWK (public modulus/exponent),
// generated with openssl. jwt.verify + crypto.verifyRsa reproduce a
// production OIDC verification entirely offline.
import { scenario, expect } from "rewind:test";
const VECTOR = {"jwk": {"kty": "RSA", "n": "uXZS2qt6hb-sMQfO4Lx-5eOZkWgLCEJA5WhjteJ2AaUQCBlh-vMzmGznetkJt37dRheHr6VY3k5aKzyXsFgNTaY9TwS_ti7FGYxbVd2rCQITFZ2W2S18I1_pfwJCLMNWApDR52gWJ_xekIqVmPHRXmUgtEwV-Jv25nQ5mHQTBEDaYfId3s_cDY0yzi0CmydcGYbVegwubMYiPuHMwjFS14ffsQQIBzrn1RvvaY6YzNLqeQY62Z5ltCkH2qaPaXNfZ5UZkf3E5kTZeuLdgn0Lz2FwwkAtZ5vjK6iuKS9CkCQoDxiL8CC3JbDpXoR0DvFX4VAz5B_IK5OrDdTfeKgAnw", "e": "AQAB"}, "token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJqZXNzIiwiaXNzIjoiaHR0cHM6Ly9pZHAudGVzdCJ9.f_e0jgUsaffmmJ6mJS1gGpY6PtWC-52FG25SqB_OE225K65biV_J98s8CrJn7JxKrqeLFs8eQ_feFGLgRgKYDwXH0_tibHO-m-lmb751S6etK8c98AJy5n-riQhU4zSkUhJhDL0IA30oGsIHY_AHeA2DCtq3uAPgkGViGWrdVfRVUrZMMU9T9Fu6SQx9uZCqpvwBxljKO4FwkNfTzEiOT8mGslyZz6_lTj-2I_urOEm4uo_MZ5ZzWIRfWCYbi2U6lQtYY2ISske8ioD0khhSJ3mFWwC0WeVwAMf3ClZ-hikhPSeEvxEOlN3g3eMV3EFaKEYvu-bQE6q502CEFQop-A"};
const req = scenario({}).inbound({ method: "POST", path: "/", body: VECTOR });
expect(req.body.rawOk).toBe(true);     // real signature verifies
expect(req.body.tampered).toBe(false); // tampered signing input rejected
expect(req.body.valid).toBe(true);     // jwt.verify agrees
expect(req.body.sub).toBe("jess");
expect(req.body.iss).toBe("https://idp.test");

// #45 step 2: RS384/RS512 verify for real (pure-JS SHA-384/512). Real tokens
// signed with a 2048-bit RSA key (Python cryptography), verified via jwt.verify
// which dispatches the header alg → crypto.verifyRsa(jwk, "sha512"/"sha384", …).
const JWK = {"kty":"RSA","n":"raeMvCV5dKW0ENAb9M7Pp6q-S6tZ4XRVQ89sqUCXwhGQf5cojbTVjFw2BlDPs-uhOZSCuATfe_BczJKEI7HFnZq3btP3a57okIPoIyI8gDAJOtn7nCS_Q_Vp-TrumIjpoBNUmA9DHXi_4EUzeOltuySXTX-sUoVOAbkul7v-Tq_B4eGODmInSqbXriStBdKBuK_uFxcACvGU7nCWpJT4yI7Z5o6OZjsu28XHICTbWH3iZSORujYbXyzg-eXKucBw_oAfYnLCJVIn2B1FKsAtBdEf-QIoH_gvWQyuPy7IrNZ6KN3Koy2PMQiwqSP5dqY19eok8PRJm9xyCdHuGQkifw","e":"AQAB"};
const RS512 = "eyJhbGciOiJSUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJqZXNzIiwiaXNzIjoiaHR0cHM6Ly9pZHAudGVzdCJ9.JY1_nEDcOHXy4KgJ7M0d3dsCgumgp_0July14nREHSY__RSkTycKJaWiBqqedR6_C6nIz2ULJ3qmwDQmPINvFomol0MrJzhWfvt2r7GC0yIE0kF6cgqEaHqSxcnzHR9zbvmf7mn9nJUoxttM1tSL5qGxQ4-YFyAKNXyHYO6jSDuQCH86cS80Y3OsEnvaskGOpp_hDdu-PvlK8qX9fGsafUVravJuOBEjUBrO8FZG-lQq1PmqvVbVrO0nrO86D93uMS6ree7F7Bm3h3oArgC-MG_bAk0hfHzkUiZ4c0YU1CeMsa4Rbd2lgLs62M44PdnhIGzmbkhVF5io4kR-uSzuvw";
const RS384 = "eyJhbGciOiJSUzM4NCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJqZXNzIiwiaXNzIjoiaHR0cHM6Ly9pZHAudGVzdCJ9.DANUKncTGVBfFBgR0xSv77RQTLPLbXKGZ9RmPSSE0OpXCyAt6bFdqvGimtQRb5lDi-X_AqFII_VwwgIXacT3lQJAh3Dcan428SRxlVW1MFHVNt2BWbZSAVOqni7J-mqxY4MYSAQCV_hq-rMi2pQrt5hNxSGEfbT07GLlkFKLdDMnVodsqYGzXLGMXhQvzu4KDYgd4RHsYywdcffXnTVziGEvBRYB3zR-MfKolgb5lodzllohYepwb6yKRPS1MeW3kQPS3kFYxC4tWXDmRWbq9OJD2y3ey86pdpUM5tQjZyJlYRVkvpEg45j4B1KvTdFWRskYlsa7eBxc-Phg4GujPw";
const rs512 = scenario({}).inbound({ method: "POST", path: "/", body: { token: RS512, jwk: JWK } });
expect(rs512.body.valid).toBe(true);
expect(rs512.body.sub).toBe("jess");
const rs384 = scenario({}).inbound({ method: "POST", path: "/", body: { token: RS384, jwk: JWK } });
expect(rs384.body.valid).toBe(true);
// A tampered RS512 token is rejected (still valid:false, not a throw).
const badRs512 = scenario({}).inbound({ method: "POST", path: "/", body: { token: RS512.slice(0, -4) + "AAAA", jwk: JWK } });
expect(badRs512.body.valid).toBe(false);

// A genuinely-unsupported alg/curve is STILL a loud declared-gap throw.
const gaps = scenario({}).inbound({ method: "GET", path: "/gaps", export: "gaps" }).body;
expect(gaps.sha1).toMatch(/not available in `rewind test`/);
expect(gaps.unknownCurve).toMatch(/crv=secp256k1/);
