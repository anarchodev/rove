// A real P-256 ES256 token + its IdP JWK (EC public point x/y), generated
// with openssl. jwt.verify + crypto.verifyEcdsa reproduce a production OIDC
// ES256 verification entirely offline — pure-JS elliptic-curve math, no OpenSSL.
import { scenario, expect } from "rewind:test";
const VECTOR = {"jwk": {"kty": "EC", "crv": "P-256", "x": "_8O_AlKnQsyk_G-M0rqKlUcV9oZevAwasjHVzOPz9T0", "y": "Isv13rzakqTqekPjuQ8wu4Vw4stX_QeCNNqPygnuz5o"}, "token": "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZGEiLCJpc3MiOiJodHRwczovL2VjLWlkcC50ZXN0In0.TP8FYfXAagwmRM0hm3J-3k-bju4KuXbVObM__T9vCyd4kbdY4MKDFwPSjmiTGEoJR8tYsNAQlguedKSEQLgZDQ"};
const req = scenario({}).inbound({ method: "POST", path: "/", body: VECTOR });
expect(req.body.rawOk).toBe(true);     // real signature verifies
expect(req.body.tampered).toBe(false); // tampered signing input rejected
expect(req.body.valid).toBe(true);     // jwt.verify agrees
expect(req.body.sub).toBe("ada");
expect(req.body.iss).toBe("https://ec-idp.test");
