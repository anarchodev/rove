// request.path excludes the ?query in the sim exactly as in prod
// (worker_dispatch strips it at the request build; the world build splits
// the authored path the same way). Live twin: ctl_smoke_v2.py step 3.
import { scenario, expect } from "rewind:test";

const s = scenario({});

const withQuery = s.inbound({ method: "GET", path: "/a/b?x=1" });
expect(withQuery.body).toBe("/a/b|x=1");

const noQuery = s.inbound({ method: "GET", path: "/a/b" });
expect(noQuery.body).toBe("/a/b|");
