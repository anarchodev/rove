// An authored bodyless inbound reads as empty, not "missing"
// (docs/plans/sim-test-framework.md). Reading request.text/.bytes on a request
// created with no `body` used to throw REPLAY DIVERGENCE — the handler aborted
// and the run reported a swallowed 200/terminal/null, so a test asserted against
// a response the handler never produced. An authored initial activation now
// defaults to an empty (readable) payload, matching prod.
import { scenario, expect } from "rewind:test";

const s = scenario({});

// bodyless GET → request.text === "" (0-length bytes), no throw
const get = s.inbound({ method: "GET", path: "/x" });
expect(get.error).toBe(null);       // did NOT abort mid-run
expect(get.body).toBe("0:0");
expect(get.status).toBe(200);

// a declared body is untouched — reads back verbatim
const post = s.inbound({ method: "POST", path: "/x", body: "hello" });
expect(post.body).toBe("5:5");

// headers-first entry is bodyless too — reading the payload there mustn't throw
const s2 = scenario({ entry: "index.mjs" });
const h = s2.inboundHeaders({ method: "PUT", path: "/x" });
expect(h.error).toBe(null);
expect(h.body).toBe("0:0");
