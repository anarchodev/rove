import { scenario, expect } from "rewind:test";
// `platform.root` is its own isolated store now — seed it via `root:`, not the
// tenant `kv:`. `platform.*` is admin-only, so the run opts in with `admin: true`.
const req = scenario({ admin: true, root: { kv: { "cfg/x": "hello" } } }).inbound({ method: "GET", path: "/" });
expect(req.status).toBe(200);
expect(req.body.surface).toEqual({ http: "object", platform: "object", browser: "object" });
expect(req.body.created).toBe("acme");
expect(req.body.rootRead).toBe("hello");
expect(req.effects.some((e) => e.kind === "platform" && e.op === "instances.create")).toBe(true);
