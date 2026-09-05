import { scenario, expect } from "rewind:test";
// `platform.root` is its own isolated store now — seed it via `root:`, not the
// tenant `kv:`. `platform.*` is admin-only, so the run opts in with `admin: true`.
const req = scenario({ admin: true, root: { kv: { "cfg/x": "hello" } } }).inbound({ method: "GET", path: "/" });
expect(req.status).toBe(200);
// browser is no longer an ambient global — it's the @rewind/browser package
// (a handler must import it). http/platform stay ambient.
expect(req.body.surface).toEqual({ http: "object", platform: "object", browser: "undefined" });
expect(req.body.rootRead).toBe("hello");
// The recorder carries the real argument (the instance name), so the effect log
// distinguishes which instance was created.
