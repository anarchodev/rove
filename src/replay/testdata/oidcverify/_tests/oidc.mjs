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
