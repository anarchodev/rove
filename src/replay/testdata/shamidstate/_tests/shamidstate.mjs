import { scenario, expect } from "rewind:test";
const r = scenario({}).inbound({ method: "GET", path: "/" }).body;

// (1) a prod s2: token (buffered "hello ") continues offline → sha256("hello world")
expect(r.crossBoundary).toBe("b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9");
// (2) the sim emits the worker's s2: format, prod-exact for Init
expect(r.initIsS2).toBe(true);
expect(r.initMatchesProd).toBe(true);
// (3) streaming across a block boundary matches the one-shot digest
expect(r.midIsS2).toBe(true);
expect(r.streamed).toBe(r.oneshot);
// (4) legacy js2: tokens still parse → sha256("abc")
expect(r.legacy).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
