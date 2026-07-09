import { scenario, expect } from "rewind:test";
const req = scenario({ kv: { "cfg/x": "hello" } }).inbound({ method: "GET", path: "/" });
expect(req.status).toBe(200);
expect(req.body.surface).toEqual({ http: "object", platform: "object", browser: "object" });
expect(req.body.created).toBe("acme");
expect(req.body.rootRead).toBe("hello");
expect(req.effects.some((e) => e.kind === "platform" && e.op === "instances.create")).toBe(true);
