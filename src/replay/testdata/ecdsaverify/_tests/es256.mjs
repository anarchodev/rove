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

// #45 step 2: ES384 (P-384 + SHA-384) and ES512 (P-521 + SHA-512) verify for
// real too — the point math is a=-3-generic; the digest is chosen by alg. Real
// tokens signed with Python cryptography, verified via jwt.verify (header alg
// → crypto.verifyEcdsa(jwk, "sha384"/"sha512", …)).
const ES384 = { jwk: {"kty":"EC","crv":"P-384","x":"MaOOoJl-b3f0fa8zVkD-uoAV7xsTBx4eYHg9KDjPoxGuXsMDrZWzLobf9xW3d6I4","y":"PeZTZFFEMR7Qe9yu2bE5ZskF2endpj_QRIKE5CGDGweZm_jYgTkl47_WTbxasmgy"},
  token: "eyJhbGciOiJFUzM4NCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJqZXNzIn0.RKsk_dtdq5X9DN3I4RcOmDXSUabd_mRoKbGulXDYIL8_4Nkl-1JY94WP3F6fDEMBTyT3p71rWwJ5dETJnMYXbVecMj8bQjITMIq7eHn1xvNm4dpAd1qY7PioUoeaOR13" };
const es384 = scenario({}).inbound({ method: "POST", path: "/", body: ES384 });
expect(es384.body.valid).toBe(true);
expect(es384.body.sub).toBe("jess");

const ES512 = { jwk: {"kty":"EC","crv":"P-521","x":"AFeheisUYHUNIWR6VYPCsL7xdezms3ZRN1ur4W8G0c__VTlRYu8rvCjl1ZLZU42tonY9v8fzgkr2kQT2p2k9bOF2","y":"AUfHTLNrLx3xFmT0-lo0tP0ZXmWyyWG8q2gF_dJVELZ0RN5PE3pt8UuSogV1bnqLsZPJTIVTLKF1tUb0qw-qb2lz"},
  token: "eyJhbGciOiJFUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJqZXNzIn0.AK6faXu4smuG1kkEMaTXPuExiEVzy-8dULKV129ZnjdgM7DWHWOcmD-vv9FOtZvOk1b6bTHlec-xvXm16EqANloLAPOO3vpmjbX56FoZgg-I_kchAYVmQIWcc7UDNSk25PxtgEHEMXe6-7x5LbA9LAWXi_T2lh5OnpQmll1hdUopG10I" };
const es512 = scenario({}).inbound({ method: "POST", path: "/", body: ES512 });
expect(es512.body.valid).toBe(true);
expect(es512.body.sub).toBe("jess");
